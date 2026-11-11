// RoNTAK native mod (UE4SS C++ mod).
//
// Gives RoNTAK's Lua mod the few things Lua can't do safely on UE4SS 3.0.1:
//
//   RoNTAK_NativeVersion() -> "0.7.0"
//
//   RoNTAK_BeginSpawn(context, class, x, y, z, yaw, collision, owner)
//       -> actor path | nil, error
//     UGameplayStatics::BeginDeferredActorSpawnFromClass. The actor exists but
//     has not run its construction script / BeginPlay yet, so Lua can set its
//     team, squad position and look first. (UE4SS 3.0.1's Lua
//     World:SpawnActor returns a broken object on this game, and Lua can't
//     pass a class argument to the spawn functions.)
//     collision: 1 always spawn, 2 adjust if possible but always spawn.
//     owner: object path or "" for none.
//
//   RoNTAK_FinishSpawn(actor, x, y, z, yaw) -> true | nil, error
//     UGameplayStatics::FinishSpawningActor.
//
//   RoNTAK_AppendObject(owner, property, element) -> count | 0 | nil, error
//     Appends element to an object array property of owner, growing the
//     array with the engine's allocator. property may go through structs:
//     "SwatAI", "SpawnedGear.Grenades". Returns the new count, or 0 when the
//     element was already in the array. (UE4SS 3.0.1's Lua array writes don't
//     grow a non-empty array and write past its end.)
//
//   RoNTAK_ArrayCount(owner, property) -> count | nil, error
//
//   RoNTAK_CreateWidget(class, owner) -> widget path | nil, error
//     UWidgetBlueprintLibrary::Create(owner, class, owner): a widget made the
//     game's way (a widget constructed from Lua never showed).
//
//   RoNTAK_SquadInstall / RoNTAK_SquadCreate / RoNTAK_SquadSet / RoNTAK_SquadStatus
//     The called-in teams' own squad manager and the hooks that route wheel
//     orders and their AI to it (see "squad routing" below).
//
//   RoNTAK_DumpCode(out_dir, seed_filters, classes, max_depth, max_mb,
//                   extra_rvas, xref_targets, field_disps)
//     Read-only: saves the game code around the wheel / squad functions for
//     reverse-engineering (see dump_code below).
//
// Objects are passed as object paths (obj:GetFullName() without the class
// name), never as raw addresses, and every one is looked up and type-checked
// here. Functions are registered into every Lua state of the "RoNTAK" Lua mod.

// PolyHook (and its asmjit) first: UE4SS's headers define short macros
// (TEXT-style string helpers) that break asmjit's headers when included later.
#define NOMINMAX
#include <polyhook2/Detour/x64Detour.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Mod/CppUserModBase.hpp>
#pragma warning(disable : 4005)
#include <Unreal/FProperty.hpp>
#include <Unreal/FScriptArray.hpp>
#include <Unreal/Property/FArrayProperty.hpp>
#include <Unreal/Property/FObjectProperty.hpp>
#include <Unreal/Property/FStructProperty.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UScriptStruct.hpp>
#pragma warning(default : 4005)

#include <algorithm>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <unordered_set>

#include <Zydis/Zydis.h>

#include <Windows.h>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr const char* NATIVE_VERSION = "0.7.0";
    constexpr const RC::CharType* LUA_MOD_NAME = STR("RoNTAK");

    // ---- Lua arguments ------------------------------------------------------
    // LuaMadeSimple's getters read and remove stack index 1, so arguments are
    // read in order. Types are checked first (lua_tostring of a non-string
    // would hand back a null pointer).

    struct Args
    {
        const LuaMadeSimple::Lua& lua;
        std::string error{};

        auto string(const char* what) -> std::string
        {
            if (!error.empty()) return {};
            if (lua.get_stack_size() < 1 || !lua.is_string())
            {
                error = std::string("expected a string for ") + what;
                return {};
            }
            return std::string(lua.get_string());
        }

        auto number(const char* what) -> double
        {
            if (!error.empty()) return 0.0;
            if (lua.get_stack_size() < 1 || !lua.is_number())
            {
                error = std::string("expected a number for ") + what;
                return 0.0;
            }
            return lua.get_number();
        }
    };

    auto fail(const LuaMadeSimple::Lua& lua, const std::string& error) -> int
    {
        // Drop whatever arguments are left, then return nil, error.
        while (lua.get_stack_size() > 0)
        {
            lua.discard_value();
        }
        lua.set_nil();
        lua.set_string(error);
        return 2;
    }

    // ---- objects and properties --------------------------------------------

    auto find_object(const std::string& path) -> UObject*
    {
        if (path.empty()) return nullptr;
        return UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, to_wstring(path));
    }

    auto path_of(UObject* object) -> std::string
    {
        // GetFullName() is "<Class> <path>"; Lua's StaticFindObject takes the path.
        auto full = to_string(object->GetFullName());
        auto space = full.find(' ');
        return space == std::string::npos ? full : full.substr(space + 1);
    }

    auto class_name_of(FProperty* property) -> std::wstring
    {
        return std::wstring(property->GetClass().GetFName().ToString());
    }

    auto value_ptr(void* container, FProperty* property) -> uint8_t*
    {
        return static_cast<uint8_t*>(container) + property->GetOffset_Internal();
    }

    auto struct_member(UScriptStruct* script_struct, const std::wstring& name) -> FProperty*
    {
        if (!script_struct) return nullptr;
        return script_struct->FindProperty(FName(name, FNAME_Add));
    }

    // Resolves "A.B.C" on an object: A on the object (or its parents), then
    // B and C inside struct properties. Gives the property and its value.
    struct Resolved
    {
        FProperty* property{};
        uint8_t* value{};
        std::string error{};
    };

    auto resolve(UObject* owner, const std::string& property_path) -> Resolved
    {
        Resolved out{};
        void* container = owner;
        UScriptStruct* in_struct = nullptr;
        size_t start = 0;
        while (true)
        {
            auto dot = property_path.find('.', start);
            auto segment = to_wstring(property_path.substr(start, dot == std::string::npos ? std::string::npos : dot - start));
            FProperty* property = in_struct ? struct_member(in_struct, segment) : owner->GetPropertyByNameInChain(segment.c_str());
            if (!property)
            {
                out.error = "no property " + to_string(segment) + " in " + property_path;
                return out;
            }
            uint8_t* value = value_ptr(container, property);
            if (dot == std::string::npos)
            {
                out.property = property;
                out.value = value;
                return out;
            }
            auto* as_struct = CastField<FStructProperty>(property);
            if (!as_struct)
            {
                out.error = to_string(segment) + " is not a struct in " + property_path;
                return out;
            }
            container = value;
            in_struct = as_struct->GetStruct();
            start = dot + 1;
        }
    }

    struct ObjectArray
    {
        FScriptArray* array{};
        FProperty* inner{};
        UClass* element_class{};
        std::string error{};
    };

    auto object_array(UObject* owner, const std::string& property_path) -> ObjectArray
    {
        ObjectArray out{};
        auto resolved = resolve(owner, property_path);
        if (!resolved.property)
        {
            out.error = resolved.error;
            return out;
        }
        if (class_name_of(resolved.property) != STR("ArrayProperty"))
        {
            out.error = property_path + " is not an array";
            return out;
        }
        auto* array_property = static_cast<FArrayProperty*>(resolved.property);
        FProperty* inner = array_property->GetInner();
        auto* inner_object = inner ? CastField<FObjectProperty>(inner) : nullptr;
        if (!inner_object || inner->GetElementSize() != sizeof(void*))
        {
            out.error = property_path + " is not an array of objects";
            return out;
        }
        out.array = reinterpret_cast<FScriptArray*>(resolved.value);
        out.inner = inner;
        out.element_class = inner_object->GetPropertyClass();
        return out;
    }

    // Writes a number into a float or double member of a struct.
    auto set_number(void* base, UScriptStruct* script_struct, const wchar_t* name, double number) -> bool
    {
        FProperty* property = struct_member(script_struct, name);
        if (!property) return false;
        auto type = class_name_of(property);
        uint8_t* value = value_ptr(base, property);
        if (type == STR("DoubleProperty"))
        {
            *reinterpret_cast<double*>(value) = number;
            return true;
        }
        if (type == STR("FloatProperty"))
        {
            *reinterpret_cast<float*>(value) = static_cast<float>(number);
            return true;
        }
        return false;
    }

    auto sub_struct(void* base, UScriptStruct* script_struct, const wchar_t* name, uint8_t*& value, UScriptStruct*& inner) -> bool
    {
        FProperty* property = struct_member(script_struct, name);
        auto* as_struct = property ? CastField<FStructProperty>(property) : nullptr;
        if (!as_struct) return false;
        value = value_ptr(base, property);
        inner = as_struct->GetStruct();
        return inner != nullptr;
    }

    // Fills an FTransform (location, yaw only, scale 1) through reflection, so
    // float (UE4) and double (UE5) layouts both work.
    auto fill_transform(uint8_t* transform, UScriptStruct* transform_struct, double x, double y, double z, double yaw_degrees) -> std::string
    {
        uint8_t* rotation{};
        uint8_t* translation{};
        uint8_t* scale{};
        UScriptStruct* quat{};
        UScriptStruct* vector{};
        UScriptStruct* scale_vector{};
        if (!sub_struct(transform, transform_struct, STR("Rotation"), rotation, quat) ||
            !sub_struct(transform, transform_struct, STR("Translation"), translation, vector) ||
            !sub_struct(transform, transform_struct, STR("Scale3D"), scale, scale_vector))
        {
            return "transform layout not found";
        }
        double half = yaw_degrees * 3.14159265358979323846 / 360.0;
        bool ok = set_number(rotation, quat, STR("X"), 0.0) && set_number(rotation, quat, STR("Y"), 0.0) &&
                  set_number(rotation, quat, STR("Z"), std::sin(half)) && set_number(rotation, quat, STR("W"), std::cos(half)) &&
                  set_number(translation, vector, STR("X"), x) && set_number(translation, vector, STR("Y"), y) &&
                  set_number(translation, vector, STR("Z"), z) && set_number(scale, scale_vector, STR("X"), 1.0) &&
                  set_number(scale, scale_vector, STR("Y"), 1.0) && set_number(scale, scale_vector, STR("Z"), 1.0);
        return ok ? std::string{} : "transform members not found";
    }

    // ---- calling GameplayStatics -------------------------------------------

    constexpr size_t PARAMS_SIZE = 0x400;

    struct Call
    {
        UObject* target{};
        UFunction* function{};
        alignas(16) uint8_t params[PARAMS_SIZE]{};
        std::string error{};

        explicit Call(const wchar_t* function_path, const wchar_t* target_path = STR("/Script/Engine.Default__GameplayStatics"))
        {
            target = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, target_path);
            function = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, function_path);
            if (!target || !function)
            {
                error = "function not found: " + to_string(std::wstring(function_path));
            }
        }

        auto param(const wchar_t* name) -> FProperty*
        {
            if (!function) return nullptr;
            for (FProperty* property : function->ForEachProperty())
            {
                if (property->HasAnyPropertyFlags(CPF_Parm) && property->GetName() == name)
                {
                    if (property->GetOffset_Internal() < 0 ||
                        static_cast<size_t>(property->GetOffset_Internal()) + property->GetElementSize() > PARAMS_SIZE)
                    {
                        return nullptr;
                    }
                    return property;
                }
            }
            return nullptr;
        }

        auto set_object(const wchar_t* name, UObject* object, bool required) -> void
        {
            if (!error.empty()) return;
            FProperty* property = param(name);
            if (!property || property->GetElementSize() != sizeof(void*))
            {
                if (required) error = "parameter " + to_string(std::wstring(name)) + " not found";
                return;
            }
            *reinterpret_cast<UObject**>(params + property->GetOffset_Internal()) = object;
        }

        auto set_byte(const wchar_t* name, uint8_t value) -> void
        {
            if (!error.empty()) return;
            FProperty* property = param(name);
            if (property && property->GetElementSize() == 1)
            {
                params[property->GetOffset_Internal()] = value;
            }
        }

        auto set_transform(const wchar_t* name, double x, double y, double z, double yaw) -> void
        {
            if (!error.empty()) return;
            FProperty* property = param(name);
            auto* as_struct = property ? CastField<FStructProperty>(property) : nullptr;
            if (!as_struct)
            {
                error = "parameter " + to_string(std::wstring(name)) + " not found";
                return;
            }
            error = fill_transform(params + property->GetOffset_Internal(), as_struct->GetStruct(), x, y, z, yaw);
        }

        auto run() -> void
        {
            if (!error.empty()) return;
            target->ProcessEvent(function, params);
        }

        auto result_object() -> UObject*
        {
            FProperty* property = param(STR("ReturnValue"));
            if (!property || property->GetElementSize() != sizeof(void*)) return nullptr;
            return *reinterpret_cast<UObject**>(params + property->GetOffset_Internal());
        }
    };

    // ---- Lua functions ------------------------------------------------------

    auto native_version(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_string(NATIVE_VERSION);
        return 1;
    }

    auto begin_spawn(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto context_path = args.string("context");
        auto class_path = args.string("class");
        double x = args.number("x");
        double y = args.number("y");
        double z = args.number("z");
        double yaw = args.number("yaw");
        double collision = args.number("collision");
        auto owner_path = args.string("owner");
        if (!args.error.empty()) return fail(lua, args.error);

        UObject* context = find_object(context_path);
        if (!context) return fail(lua, "context not found: " + context_path);
        UObject* class_object = find_object(class_path);
        if (!class_object || !class_object->IsA<UClass>()) return fail(lua, "class not found: " + class_path);
        auto* actor_class = static_cast<UClass*>(class_object);
        UObject* owner = nullptr;
        if (!owner_path.empty())
        {
            owner = find_object(owner_path);
            if (!owner) return fail(lua, "owner not found: " + owner_path);
        }

        Call call{STR("/Script/Engine.GameplayStatics:BeginDeferredActorSpawnFromClass")};
        call.set_object(STR("WorldContextObject"), context, true);
        call.set_object(STR("ActorClass"), actor_class, true);
        call.set_transform(STR("SpawnTransform"), x, y, z, yaw);
        call.set_byte(STR("CollisionHandlingOverride"), static_cast<uint8_t>(collision));
        call.set_object(STR("Owner"), owner, false);
        call.set_byte(STR("TransformScaleMethod"), 1); // MultiplyWithRoot, the default
        if (!call.error.empty()) return fail(lua, call.error);
        call.run();
        UObject* actor = call.result_object();
        if (!actor) return fail(lua, "the game did not spawn " + class_path);
        lua.set_string(path_of(actor));
        return 1;
    }

    auto finish_spawn(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto actor_path = args.string("actor");
        double x = args.number("x");
        double y = args.number("y");
        double z = args.number("z");
        double yaw = args.number("yaw");
        if (!args.error.empty()) return fail(lua, args.error);

        UObject* actor = find_object(actor_path);
        if (!actor) return fail(lua, "actor not found: " + actor_path);

        Call call{STR("/Script/Engine.GameplayStatics:FinishSpawningActor")};
        call.set_object(STR("Actor"), actor, true);
        call.set_transform(STR("SpawnTransform"), x, y, z, yaw);
        call.set_byte(STR("TransformScaleMethod"), 1);
        if (!call.error.empty()) return fail(lua, call.error);
        call.run();
        lua.set_bool(true);
        return 1;
    }

    // UWidgetBlueprintLibrary::Create, the game's own way to make a widget
    // (initialised, ready for AddToViewport). Lua can't pass its class argument.
    auto create_widget(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto class_path = args.string("class");
        auto owner_path = args.string("owner");
        if (!args.error.empty()) return fail(lua, args.error);

        UObject* class_object = find_object(class_path);
        if (!class_object || !class_object->IsA<UClass>()) return fail(lua, "class not found: " + class_path);
        UObject* owner = find_object(owner_path);
        if (!owner) return fail(lua, "owner not found: " + owner_path);

        Call call{STR("/Script/UMG.WidgetBlueprintLibrary:Create"), STR("/Script/UMG.Default__WidgetBlueprintLibrary")};
        call.set_object(STR("WorldContextObject"), owner, true);
        call.set_object(STR("WidgetType"), class_object, true);
        call.set_object(STR("OwningPlayer"), owner, false);
        if (!call.error.empty()) return fail(lua, call.error);
        call.run();
        UObject* widget = call.result_object();
        if (!widget) return fail(lua, "the game did not create " + class_path);
        lua.set_string(path_of(widget));
        return 1;
    }

    auto append_object(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto owner_path = args.string("owner");
        auto property_path = args.string("property");
        auto element_path = args.string("element");
        if (!args.error.empty()) return fail(lua, args.error);

        UObject* owner = find_object(owner_path);
        if (!owner) return fail(lua, "owner not found: " + owner_path);
        UObject* element = find_object(element_path);
        if (!element) return fail(lua, "element not found: " + element_path);
        auto found = object_array(owner, property_path);
        if (!found.array) return fail(lua, found.error);
        if (found.element_class && !element->IsA(found.element_class))
        {
            return fail(lua, path_of(element) + " does not fit in " + property_path);
        }

        auto** data = static_cast<UObject**>(found.array->GetData());
        int32_t count = found.array->Num();
        for (int32_t i = 0; i < count; ++i)
        {
            if (data[i] == element)
            {
                lua.set_integer(0);
                return 1;
            }
        }
        found.array->AddZeroed(1, found.inner->GetElementSize(), DEFAULT_ALIGNMENT);
        if (found.array->Num() != count + 1) return fail(lua, "could not grow " + property_path);
        data = static_cast<UObject**>(found.array->GetData()); // may have moved
        data[count] = element;
        lua.set_integer(found.array->Num());
        return 1;
    }

    auto array_count(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto owner_path = args.string("owner");
        auto property_path = args.string("property");
        if (!args.error.empty()) return fail(lua, args.error);

        UObject* owner = find_object(owner_path);
        if (!owner) return fail(lua, "owner not found: " + owner_path);
        auto found = object_array(owner, property_path);
        if (!found.array) return fail(lua, found.error);
        lua.set_integer(found.array->Num());
        return 1;
    }

    // ---- code dump (reverse-engineering the wheel and squad code) -----------
    //
    // RoNTAK_DumpCode(out_dir, seed_filters, classes, max_depth, max_mb,
    //                 extra_rvas, xref_targets, field_disps) -> summary | nil, error
    //   extra_rvas: more seeds by address; xref_targets: list every call / jump
    //   to these (xrefs.txt); field_disps: list every memory use of these
    //   displacements (fields.txt). All comma-separated hex, may be empty.
    // Read-only. Writes into out_dir:
    //   header.txt     image base, size, sections
    //   functions.txt  every native ReadyOrNot UFunction: rva, name
    //   vtables.txt    vtables of live objects of the given classes
    //   index.txt      the dumped functions: rva, size, offset in code.bin, depth, why
    //   code.bin       their bytes
    //   pdata.bin      the exception directory (every function's start / end)
    //   data.txt       rip-relative data the dumped code reads (rva, 64 bytes hex)
    // Seeds: the native UFunctions whose names contain one of seed_filters
    // (comma separated, e.g. "SWATManager:,SwatCommandWidget:") and the vtable
    // entries of live objects of classes (comma separated). From each seed the
    // direct calls and jumps are followed to max_depth (Zydis decoding, the
    // function bounds from .pdata), up to max_mb of code.

    struct RuntimeFunction
    {
        uint32_t begin;
        uint32_t end;
        uint32_t unwind;
    };

    struct Image
    {
        uint8_t* base{};
        uint32_t size{};
        uint32_t text_begin{}, text_end{};
        std::vector<RuntimeFunction> functions{};
        uint32_t pdata_rva{}, pdata_size{};
        std::string sections{};
    };

    auto read_image() -> Image
    {
        Image img{};
        img.base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(img.base);
        auto* nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(img.base + dos->e_lfanew);
        img.size = nt->OptionalHeader.SizeOfImage;
        auto* section = IMAGE_FIRST_SECTION(nt);
        std::ostringstream out;
        for (int i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section)
        {
            char name[9]{};
            std::memcpy(name, section->Name, 8);
            out << name << " rva=" << std::hex << section->VirtualAddress << " size=" << section->Misc.VirtualSize
                << " flags=" << section->Characteristics << std::dec << "\n";
            if ((section->Characteristics & IMAGE_SCN_MEM_EXECUTE) && img.text_end == 0)
            {
                img.text_begin = section->VirtualAddress;
                img.text_end = section->VirtualAddress + section->Misc.VirtualSize;
            }
        }
        img.sections = out.str();
        auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
        img.pdata_rva = dir.VirtualAddress;
        img.pdata_size = dir.Size;
        auto* entries = reinterpret_cast<RuntimeFunction*>(img.base + dir.VirtualAddress);
        img.functions.assign(entries, entries + dir.Size / sizeof(RuntimeFunction));
        std::sort(img.functions.begin(), img.functions.end(), [](auto& a, auto& b) { return a.begin < b.begin; });
        return img;
    }

    auto function_at(const Image& img, uint32_t rva) -> const RuntimeFunction*
    {
        auto it = std::upper_bound(img.functions.begin(), img.functions.end(), rva,
                                   [](uint32_t value, const RuntimeFunction& f) { return value < f.begin; });
        if (it == img.functions.begin()) return nullptr;
        --it;
        return rva < it->end ? &*it : nullptr;
    }

    auto split(const std::string& text) -> std::vector<std::string>
    {
        std::vector<std::string> out;
        std::string part;
        std::istringstream in(text);
        while (std::getline(in, part, ','))
        {
            if (!part.empty()) out.push_back(part);
        }
        return out;
    }

    auto hex(uint64_t v) -> std::string
    {
        std::ostringstream o;
        o << std::hex << v;
        return o.str();
    }

    auto dump_code(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto out_dir = args.string("out_dir");
        auto filters = split(args.string("seed_filters"));
        auto classes = split(args.string("classes"));
        int max_depth = static_cast<int>(args.number("max_depth"));
        double max_mb = args.number("max_mb");
        auto extra_rvas = split(args.string("extra_rvas"));
        auto xref_list = split(args.string("xref_targets"));
        auto field_list = split(args.string("field_disps"));
        if (!args.error.empty()) return fail(lua, args.error);
        auto parse_hex = [](const std::string& t) -> uint64_t {
            try { return std::stoull(t, nullptr, 16); } catch (...) { return 0; }
        };

        Image img = read_image();
        if (img.functions.empty() || img.text_end == 0) return fail(lua, "could not read the game's image");
        auto in_text = [&](uint64_t rva) { return rva >= img.text_begin && rva < img.text_end; };
        auto rva_of = [&](const void* p) -> uint64_t {
            auto a = reinterpret_cast<const uint8_t*>(p);
            return (a >= img.base && a < img.base + img.size) ? static_cast<uint64_t>(a - img.base) : 0;
        };

        std::wstring dir = to_wstring(out_dir);
        std::error_code mkdir_error;
        std::filesystem::create_directories(dir, mkdir_error);
        std::ofstream functions_out(dir + L"\\functions.txt");
        std::ofstream vtables_out(dir + L"\\vtables.txt");
        if (!functions_out) return fail(lua, "could not write to " + out_dir);

        std::deque<std::pair<uint32_t, int>> queue;
        std::map<uint32_t, std::string> why;

        // Native UFunctions: all listed, the filtered ones seeded.
        size_t ufunctions = 0;
        UObjectGlobals::ForEachUObject([&](void* raw, int32_t, int32_t) {
            auto* object = static_cast<UObject*>(raw);
            if (!object || !object->IsA<UFunction>()) return LoopAction::Continue;
            auto* function = static_cast<UFunction*>(object);
            if (!function->HasAnyFunctionFlags(FUNC_Native)) return LoopAction::Continue;
            auto name = to_string(function->GetFullName());
            if (name.find("/Script/ReadyOrNot.") == std::string::npos) return LoopAction::Continue;
            uint64_t rva = rva_of(reinterpret_cast<const void*>(function->GetFunc()));
            if (!rva) return LoopAction::Continue;
            functions_out << hex(rva) << " " << name << "\n";
            ++ufunctions;
            for (auto& f : filters)
            {
                if (name.find(f) != std::string::npos)
                {
                    queue.emplace_back(static_cast<uint32_t>(rva), 0);
                    why.emplace(static_cast<uint32_t>(rva), "ufunction " + name);
                    break;
                }
            }
            return LoopAction::Continue;
        });

        // Vtables of live objects (virtual calls can't be followed otherwise).
        for (auto& class_name : classes)
        {
            std::vector<UObject*> found;
            UObjectGlobals::FindAllOf(to_wstring(class_name), found);
            if (found.empty())
            {
                vtables_out << class_name << ": no live object\n";
                continue;
            }
            UObject* object = found.front();
            auto vtable = *reinterpret_cast<uintptr_t**>(object);
            vtables_out << class_name << " " << to_string(object->GetFullName()) << " vtable=" << hex(rva_of(vtable)) << "\n";
            if (!rva_of(vtable)) continue;
            for (int i = 0; i < 512; ++i)
            {
                uint64_t entry = rva_of(reinterpret_cast<const void*>(vtable[i]));
                if (!entry || !in_text(entry)) break;
                vtables_out << "  [" << i << "] " << hex(entry) << "\n";
                queue.emplace_back(static_cast<uint32_t>(entry), 1);
                why.emplace(static_cast<uint32_t>(entry), class_name + " vtable[" + std::to_string(i) + "]");
            }
        }

        ZydisDecoder decoder{};
        ZydisDecoderInit(&decoder, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);

        // Extra seeds by address.
        for (auto& t : extra_rvas)
        {
            uint64_t rva = parse_hex(t);
            if (rva && in_text(rva))
            {
                queue.emplace_front(static_cast<uint32_t>(rva), 0);
                why.emplace(static_cast<uint32_t>(rva), "requested");
            }
        }

        // Whole-program scan: calls / jumps to xref_targets, and memory
        // operands with a displacement in field_disps (who reads / writes a
        // field). The containing functions are dumped too.
        std::set<uint64_t> xref_targets, field_disps;
        for (auto& t : xref_list) if (auto v = parse_hex(t)) xref_targets.insert(v);
        for (auto& t : field_list) if (auto v = parse_hex(t)) field_disps.insert(v);
        size_t xref_count = 0, field_count = 0;
        if (!xref_targets.empty() || !field_disps.empty())
        {
            std::ofstream xrefs_out(dir + L"\\xrefs.txt");
            std::ofstream fields_out(dir + L"\\fields.txt");
            std::map<uint64_t, size_t> per_field;
            ZydisDecodedInstruction ins{};
            ZydisDecodedOperand ops[ZYDIS_MAX_OPERAND_COUNT]{};
            for (auto& f : img.functions)
            {
                if (!in_text(f.begin) || f.end <= f.begin || f.end - f.begin > 1024 * 1024) continue;
                uint32_t off = 0, len = f.end - f.begin;
                while (off < len)
                {
                    const uint8_t* at = img.base + f.begin + off;
                    if (!ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, at, len - off, &ins, ops)))
                    {
                        off += 1;
                        continue;
                    }
                    for (int i = 0; i < ins.operand_count_visible; ++i)
                    {
                        auto& op = ops[i];
                        if (!xref_targets.empty() && op.type == ZYDIS_OPERAND_TYPE_IMMEDIATE && op.imm.is_relative)
                        {
                            ZyanU64 target{};
                            if (ZYAN_SUCCESS(ZydisCalcAbsoluteAddress(&ins, &op, reinterpret_cast<uint64_t>(at), &target)))
                            {
                                uint64_t trva = rva_of(reinterpret_cast<const void*>(target));
                                if (xref_targets.count(trva))
                                {
                                    xrefs_out << hex(trva) << " " << hex(f.begin + off) << " " << hex(f.begin) << "\n";
                                    ++xref_count;
                                    if (xref_count < 3000)
                                    {
                                        queue.emplace_back(f.begin, 0);
                                        why.emplace(f.begin, "xref " + hex(trva));
                                    }
                                }
                            }
                        }
                        if (!field_disps.empty() && op.type == ZYDIS_OPERAND_TYPE_MEMORY && op.mem.base != ZYDIS_REGISTER_RIP &&
                            op.mem.base != ZYDIS_REGISTER_RSP && op.mem.base != ZYDIS_REGISTER_RBP)
                        {
                            uint64_t disp = static_cast<uint64_t>(op.mem.disp.value);
                            if (field_disps.count(disp) && per_field[disp] < 4000)
                            {
                                bool write = (op.actions & ZYDIS_OPERAND_ACTION_MASK_WRITE) != 0;
                                fields_out << hex(disp) << " " << (write ? "w" : "r") << " " << op.size << " "
                                           << hex(f.begin + off) << " " << hex(f.begin) << "\n";
                                ++per_field[disp];
                                ++field_count;
                                if (write && op.size == 8)
                                {
                                    queue.emplace_back(f.begin, 0);
                                    why.emplace(f.begin, "writes " + hex(disp));
                                }
                            }
                        }
                    }
                    off += ins.length;
                }
            }
        }

        std::ofstream code_out(dir + L"\\code.bin", std::ios::binary);
        std::ofstream index_out(dir + L"\\index.txt");
        std::ofstream data_out(dir + L"\\data.txt");
        std::set<uint32_t> dumped;
        std::set<uint32_t> data_seen;
        uint64_t written = 0;
        const uint64_t limit = static_cast<uint64_t>(max_mb * 1024 * 1024);
        size_t count = 0;

        while (!queue.empty() && written < limit)
        {
            auto [rva, depth] = queue.front();
            queue.pop_front();
            const RuntimeFunction* f = function_at(img, rva);
            uint32_t begin = f ? f->begin : rva;
            uint32_t end = f ? f->end : rva + 256;
            if (!in_text(begin) || dumped.count(begin)) continue;
            dumped.insert(begin);
            uint32_t size = std::min<uint32_t>(end - begin, 256 * 1024);
            // A function piece that runs straight into the next .pdata entry
            // (no padding between them) continues the same function.
            if (f)
            {
                const RuntimeFunction* next = function_at(img, f->end);
                if (next && next->begin == f->end && !dumped.count(next->begin))
                {
                    queue.emplace_front(next->begin, depth);
                }
            }
            code_out.write(reinterpret_cast<const char*>(img.base + begin), size);
            index_out << hex(begin) << " " << hex(size) << " " << hex(written) << " " << depth << " "
                      << (why.count(rva) ? why[rva] : "call") << "\n";
            written += size;
            ++count;

            // Follow direct calls / jumps; note rip-relative data.
            ZydisDecodedInstruction instruction{};
            ZydisDecodedOperand operands[ZYDIS_MAX_OPERAND_COUNT]{};
            uint32_t offset = 0;
            while (offset < size)
            {
                const uint8_t* at = img.base + begin + offset;
                if (!ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, at, size - offset, &instruction, operands)))
                {
                    offset += 1;
                    continue;
                }
                uint64_t runtime = reinterpret_cast<uint64_t>(at);
                for (int i = 0; i < instruction.operand_count_visible; ++i)
                {
                    auto& op = operands[i];
                    bool branch = instruction.meta.category == ZYDIS_CATEGORY_CALL ||
                                  instruction.meta.category == ZYDIS_CATEGORY_UNCOND_BR;
                    bool jump = instruction.meta.category == ZYDIS_CATEGORY_COND_BR ||
                                instruction.meta.category == ZYDIS_CATEGORY_UNCOND_BR;
                    bool relative_imm = op.type == ZYDIS_OPERAND_TYPE_IMMEDIATE && op.imm.is_relative;
                    bool rip_mem = op.type == ZYDIS_OPERAND_TYPE_MEMORY && op.mem.base == ZYDIS_REGISTER_RIP;
                    if (!relative_imm && !rip_mem) continue;
                    ZyanU64 target{};
                    if (!ZYAN_SUCCESS(ZydisCalcAbsoluteAddress(&instruction, &op, runtime, &target))) continue;
                    uint64_t target_rva = rva_of(reinterpret_cast<const void*>(target));
                    if (!target_rva) continue;
                    bool outside = target_rva < begin || target_rva >= begin + size;
                    if (relative_imm && jump && in_text(target_rva) && outside)
                    {
                        // Another part of the same function (the compiler splits
                        // large functions into separate .pdata entries).
                        queue.emplace_front(static_cast<uint32_t>(target_rva), depth);
                    }
                    else if (relative_imm && branch && in_text(target_rva))
                    {
                        if (depth < max_depth) queue.emplace_back(static_cast<uint32_t>(target_rva), depth + 1);
                    }
                    else if (rip_mem && !in_text(target_rva) && data_seen.size() < 50000 &&
                             data_seen.insert(static_cast<uint32_t>(target_rva)).second &&
                             target_rva + 64 <= img.size)
                    {
                        data_out << hex(target_rva) << " ";
                        for (int b = 0; b < 64; ++b)
                        {
                            static const char* digits = "0123456789abcdef";
                            uint8_t v = img.base[target_rva + b];
                            data_out << digits[v >> 4] << digits[v & 15];
                        }
                        data_out << "\n";
                    }
                }
                offset += instruction.length;
            }
        }

        std::ofstream pdata_out(dir + L"\\pdata.bin", std::ios::binary);
        pdata_out.write(reinterpret_cast<const char*>(img.base + img.pdata_rva), img.pdata_size);
        std::ofstream header_out(dir + L"\\header.txt");
        header_out << "base=" << hex(reinterpret_cast<uint64_t>(img.base)) << " size=" << hex(img.size)
                   << " text=" << hex(img.text_begin) << "-" << hex(img.text_end)
                   << " pdata=" << hex(img.pdata_rva) << "+" << hex(img.pdata_size) << "\n"
                   << img.sections;

        std::ostringstream summary;
        summary << count << " functions (" << written / 1024 << " KB), " << ufunctions << " UFunctions listed, "
                << data_seen.size() << " data references, " << xref_count << " xrefs, " << field_count << " field uses"
                << (queue.empty() ? "" : " (size limit reached)");
        lua.set_string(summary.str());
        return 1;
    }

    // ---- squad routing (the called-in teams' own squad manager) ------------
    //
    // The command wheel's DoCommand asks a resolver for the world's squad
    // manager (USWATManager) and gives it the order; the officers' team
    // activities ask the same resolver while they run. RoNTAK gives the
    // called-in teams a second manager and hooks:
    //   resolver   a wheel order marked for the call-ins, or a call-in officer
    //              (or anything inside one: its controller, activities,
    //              components) asking, gets the second manager;
    //   DoCommand  marks the order: group 0 the main manager (plain game),
    //              1 the call-ins' manager, 2 both (the full element).
    // The hooks are installed only if the game code at these addresses is
    // exactly what was analysed (native/RE_NOTES.md); after a game update
    // they stay off.

    namespace route
    {
        // Where the analysed build (Nov 2026) had them, for the log only: the
        // functions are found by what they do (see find_game_code), so a game
        // update that moves them doesn't switch routing off.
        constexpr uint32_t KNOWN_RESOLVER = 0x4dd1090;
        constexpr uint32_t KNOWN_DOCOMMAND = 0x4ca7e10;
        constexpr uint32_t KNOWN_SCROLL = 0x4ca7710;
        constexpr uint32_t KNOWN_SET_TEAM = 0x4cc32d0;
        constexpr uint32_t KNOWN_TEAM_DEAD = 0x4de8b50;
        constexpr int KNOWN_INITIALIZE_SLOT = 88;

        // Found at install time.
        uint32_t resolver_rva = 0, docommand_rva = 0, scroll_rva = 0, set_team_rva = 0, team_dead_rva = 0;
        uint32_t widget_team = 0;                       // SwatCommandWidget::ActiveTeamType offset (reflection)

        uint64_t resolver_trampoline = 0;
        uint64_t docommand_trampoline = 0;
        uint64_t scroll_trampoline = 0;
        std::unique_ptr<PLH::x64Detour> resolver_detour;
        std::unique_ptr<PLH::x64Detour> docommand_detour;
        std::unique_ptr<PLH::x64Detour> scroll_detour;
        bool installed = false;
        bool scroll_installed = false;
        uint8_t* game_base = nullptr;

        UObject* element_manager = nullptr;      // the call-ins' manager
        UObject* command_manager = nullptr;      // set while a wheel order is routed
        int group = 0;                           // 0 main, 1 call-ins, 2 both
        bool in_command = false;
        std::unordered_set<const void*> members; // call-in actors and their controllers (compared, never used)
        uint64_t redirects = 0, commands = 0, scrolls = 0;

        using ResolverFn = UObject* (*)(UObject*);
        using DoCommandFn = uint64_t (*)(void*, void*, uint64_t, uint64_t, void*);
        using ScrollFn = void (*)(void*, uint64_t, uint64_t);
        using SetTeamFn = void (*)(void*, uint64_t);
        using TeamDeadFn = bool (*)(UObject*, uint64_t);

        UObject* main_manager = nullptr;         // the world's own manager when routing was set

        UObject* resolver_hook(UObject* context)
        {
            auto original = reinterpret_cast<ResolverFn>(resolver_trampoline);
            if (!element_manager) return original(context);
            // Only in the world the call-ins' manager was made for: after a
            // map change the old pointers are stale and must never be used.
            UObject* main = original(context);
            if (main != main_manager) return main;
            if (command_manager)
            {
                ++redirects;
                return command_manager;
            }
            if (context && !members.empty())
            {
                UObject* o = context;
                for (int i = 0; i < 6 && o; ++i)
                {
                    if (members.count(o))
                    {
                        ++redirects;
                        return element_manager;
                    }
                    o = o->GetOuterPrivate();
                }
            }
            return main;
        }

        uint64_t docommand_hook(void* widget, void* command, uint64_t a3, uint64_t a4, void* a5)
        {
            auto original = reinterpret_cast<DoCommandFn>(docommand_trampoline);
            if (!element_manager || group == 0 || in_command)
            {
                return original(widget, command, a3, a4, a5);
            }
            in_command = true;
            ++commands;
            uint64_t result = 0;
            if (group == 2)
            {
                // DoCommand adjusts the command's location in place: give the
                // second run the same command as the first.
                alignas(16) uint8_t saved[0x200];
                if (a5) std::memcpy(saved, a5, sizeof(saved));
                result = original(widget, command, a3, a4, a5);
                if (a5) std::memcpy(a5, saved, sizeof(saved));
            }
            command_manager = element_manager;
            result = original(widget, command, a3, a4, a5);
            command_manager = nullptr;
            in_command = false;
            return result;
        }

        // The wheel's team scroll with the called-in teams' manager on: one list
        //   RED, BLUE, RED+BLUE, GREEN, YELLOW, GREEN+YELLOW, FULL ELEMENT
        // as (group, wheel team): the wheel keeps showing red / blue / gold and
        // RoNTAK's on-screen label names the real choice. Teams that are down
        // are skipped, like the game does.
        struct WheelEntry
        {
            int group;
            uint8_t team;
        };
        constexpr WheelEntry WHEEL[] = {{0, 1}, {0, 2}, {0, 5}, {1, 2}, {1, 1}, {1, 5}, {2, 5}};
        constexpr int WHEEL_SIZE = sizeof(WHEEL) / sizeof(WHEEL[0]);
        bool in_scroll = false;

        auto team_dead(UObject* manager, uint8_t team) -> bool
        {
            return reinterpret_cast<TeamDeadFn>(game_base + team_dead_rva)(manager, team);
        }

        auto entry_usable(const WheelEntry& e) -> bool
        {
            if (e.group == 0) return !team_dead(main_manager, e.team);
            if (e.group == 1) return !team_dead(element_manager, e.team);
            return !team_dead(main_manager, 5) && !team_dead(element_manager, 5);
        }

        void scroll_hook(void* widget, uint64_t forward, uint64_t flag)
        {
            auto original = reinterpret_cast<ScrollFn>(scroll_trampoline);
            UObject* main = widget ? reinterpret_cast<ResolverFn>(resolver_trampoline)(static_cast<UObject*>(widget)) : nullptr;
            // The game's own scroll unless the call-ins have a manager in this
            // world with someone up in it.
            if (in_scroll || !element_manager || !main || main != main_manager || team_dead(element_manager, 5))
            {
                if (element_manager && main == main_manager && !in_scroll) group = 0;
                original(widget, forward, flag);
                return;
            }
            in_scroll = true;
            ++scrolls;
            uint8_t shown = *(static_cast<uint8_t*>(widget) + widget_team);
            int at = -1;
            for (int i = 0; i < WHEEL_SIZE; ++i)
            {
                if (WHEEL[i].group == group && WHEEL[i].team == shown) at = i;
            }
            if (at < 0) at = 0;
            int step = (forward & 0xff) ? 1 : -1;
            int next = at;
            for (int k = 1; k <= WHEEL_SIZE; ++k)
            {
                int i = ((at + step * k) % WHEEL_SIZE + WHEEL_SIZE) % WHEEL_SIZE;
                if (entry_usable(WHEEL[i]))
                {
                    next = i;
                    break;
                }
            }
            group = WHEEL[next].group;
            // Set the wheel's team with the chosen squad's manager answering
            // (the game's set-team checks that team in it).
            command_manager = group == 1 ? element_manager : nullptr;
            reinterpret_cast<SetTeamFn>(game_base + set_team_rva)(widget, WHEEL[next].team);
            command_manager = nullptr;
            in_scroll = false;
        }

        // ---- finding the game code -------------------------------------
        //
        // Each function is recognised by what it does, anchored on things a
        // game update keeps: UFunction exec thunks (found by name through
        // reflection) and property offsets (reflection too).
        //
        //   IsSWATTeamDead  the call in the exec thunk of
        //                   SWATManager:IsSWATTeamDead
        //   DoCommand       the call in the exec thunk of
        //                   SwatCommandWidget:DoCommand whose code first asks a
        //                   GetSubsystem-shaped function (the resolver) and
        //                   uses the widget's ExecutionTeamType
        //   resolver        that GetSubsystem-shaped function
        //   team scroll     the one function whose first call is the resolver,
        //                   that asks IsSWATTeamDead(5), clears ActiveTeamType
        //                   and calls set-team
        //   set-team        reads ActiveTeamType, writes the byte after it
        //                   (PreviousActiveTeamType), asks the resolver and
        //                   IsSWATTeamDead
        //
        // Anything not found exactly once stays unhooked (and says why).

        struct Call
        {
            uint32_t target;
            int dl;  // the value set in dl just before the call, or -1
        };
        struct MemUse
        {
            uint32_t at;      // offset from the function start
            int64_t disp;
            ZydisRegister base;
            bool write;
            bool zero;        // writes the constant 0
        };
        struct Body
        {
            uint32_t begin = 0, end = 0;
            std::vector<Call> calls;
            std::vector<MemUse> mems;
            uint32_t last_jump = 0;   // target of the last direct jmp
            bool early_virtual_call = false;
        };

        struct Finder
        {
            Image img;
            std::vector<uint32_t> primaries;  // .pdata entries that start a function (not chained pieces)
            ZydisDecoder decoder{};

            Finder() : img(read_image())
            {
                ZydisDecoderInit(&decoder, ZYDIS_MACHINE_MODE_LONG_64, ZYDIS_STACK_WIDTH_64);
                for (auto& f : img.functions)
                {
                    if (f.unwind >= img.size) continue;
                    uint8_t flags = img.base[f.unwind] >> 3;  // UNWIND_INFO: version 3 bits, flags 5 bits
                    if (!(flags & 0x4)) primaries.push_back(f.begin);  // not UNW_FLAG_CHAININFO
                }
                std::sort(primaries.begin(), primaries.end());
            }

            auto in_text(uint64_t rva) const -> bool { return rva >= img.text_begin && rva < img.text_end; }

            auto rva_of(const void* p) const -> uint32_t
            {
                auto a = static_cast<const uint8_t*>(p);
                return (a >= img.base && a < img.base + img.size) ? static_cast<uint32_t>(a - img.base) : 0;
            }

            // The function start at or before rva.
            auto start_of(uint32_t rva) const -> uint32_t
            {
                auto it = std::upper_bound(primaries.begin(), primaries.end(), rva);
                return it == primaries.begin() ? 0 : *(it - 1);
            }

            // A function's code: from its start to the next function's start.
            auto body(uint32_t rva, uint32_t max = 0x6000) const -> Body
            {
                Body b{};
                if (!in_text(rva)) return b;
                auto it = std::upper_bound(primaries.begin(), primaries.end(), rva);
                uint32_t end = it == primaries.end() ? img.text_end : *it;
                end = std::min<uint32_t>({end, rva + max, img.text_end});
                b.begin = rva;
                b.end = end;
                ZydisDecodedInstruction ins{};
                ZydisDecodedOperand ops[ZYDIS_MAX_OPERAND_COUNT]{};
                int dl = -1;
                uint32_t off = rva;
                while (off < end)
                {
                    const uint8_t* at = img.base + off;
                    if (!ZYAN_SUCCESS(ZydisDecoderDecodeFull(&decoder, at, end - off, &ins, ops)))
                    {
                        off += 1;
                        continue;
                    }
                    uint64_t runtime = reinterpret_cast<uint64_t>(at);
                    bool is_call = ins.meta.category == ZYDIS_CATEGORY_CALL;
                    bool is_jmp = ins.mnemonic == ZYDIS_MNEMONIC_JMP;
                    if ((is_call || is_jmp) && ins.operand_count_visible > 0)
                    {
                        auto& op = ops[0];
                        if (op.type == ZYDIS_OPERAND_TYPE_IMMEDIATE && op.imm.is_relative)
                        {
                            ZyanU64 target{};
                            if (ZYAN_SUCCESS(ZydisCalcAbsoluteAddress(&ins, &op, runtime, &target)))
                            {
                                uint32_t t = rva_of(reinterpret_cast<const void*>(target));
                                if (is_call && t) b.calls.push_back({t, dl});
                                if (is_jmp && t && (t < rva || t >= end)) b.last_jump = t;
                            }
                        }
                        else if (is_call && op.type == ZYDIS_OPERAND_TYPE_MEMORY && op.mem.base != ZYDIS_REGISTER_RIP &&
                                 off - rva < 0x20)
                        {
                            b.early_virtual_call = true;
                        }
                    }
                    // Track a constant put in dl for the next call (the team argument).
                    if (is_call)
                    {
                        dl = -1;
                    }
                    else if (ins.operand_count_visible >= 2 && ops[0].type == ZYDIS_OPERAND_TYPE_REGISTER)
                    {
                        auto r = ops[0].reg.value;
                        bool rdx = r == ZYDIS_REGISTER_DL || r == ZYDIS_REGISTER_DX || r == ZYDIS_REGISTER_EDX || r == ZYDIS_REGISTER_RDX;
                        if (rdx)
                        {
                            if (ins.mnemonic == ZYDIS_MNEMONIC_MOV && ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE)
                                dl = static_cast<int>(ops[1].imm.value.u & 0xff);
                            else if (ins.mnemonic == ZYDIS_MNEMONIC_XOR && ops[1].type == ZYDIS_OPERAND_TYPE_REGISTER &&
                                     ops[1].reg.value == r)
                                dl = 0;
                            else
                                dl = -1;
                        }
                    }
                    for (int i = 0; i < ins.operand_count_visible; ++i)
                    {
                        auto& op = ops[i];
                        if (op.type != ZYDIS_OPERAND_TYPE_MEMORY || op.mem.base == ZYDIS_REGISTER_RIP ||
                            op.mem.base == ZYDIS_REGISTER_RSP || !op.mem.disp.has_displacement)
                            continue;
                        bool write = (op.actions & ZYDIS_OPERAND_ACTION_MASK_WRITE) != 0;
                        bool zero = write && i == 0 && ins.operand_count_visible >= 2 && ops[1].type == ZYDIS_OPERAND_TYPE_IMMEDIATE &&
                                    ops[1].imm.value.u == 0;
                        b.mems.push_back({off - rva, op.mem.disp.value, op.mem.base, write, zero});
                    }
                    off += ins.length;
                }
                return b;
            }

            static auto uses(const Body& b, int64_t disp, bool want_write = false, bool want_zero = false,
                             uint32_t within = 0xffffffff) -> bool
            {
                for (auto& m : b.mems)
                {
                    if (m.disp != disp || m.at >= within) continue;
                    if (want_write && !m.write) continue;
                    if (want_zero && !m.zero) continue;
                    return true;
                }
                return false;
            }

            static auto calls_to(const Body& b, uint32_t target) -> bool
            {
                for (auto& c : b.calls)
                    if (c.target == target) return true;
                return false;
            }

            // The shape of an inlined GetWorld()->GetSubsystem<T>(): a virtual
            // call first, the class asked twice, a tail jump; small.
            auto looks_like_resolver(uint32_t rva) const -> bool
            {
                Body b = body(rva, 0x100);
                if (!b.early_virtual_call || !b.last_jump || b.calls.empty() || b.calls.size() > 3) return false;
                for (auto& c : b.calls)
                    if (c.target != b.calls[0].target) return false;
                return true;
            }
        };

        auto ufunction_rva(const Finder& f, const wchar_t* path) -> uint32_t
        {
            UObject* object = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, std::wstring(path));
            if (!object || !object->IsA<UFunction>()) return 0;
            return f.rva_of(reinterpret_cast<const void*>(static_cast<UFunction*>(object)->GetFunc()));
        }

        auto property_offset(const wchar_t* object_path, const wchar_t* property) -> int64_t
        {
            UObject* object = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, std::wstring(object_path));
            if (!object) return -1;
            FProperty* p = object->GetPropertyByNameInChain(property);
            return p ? p->GetOffset_Internal() : -1;
        }

        auto hex32(uint32_t v) -> std::string
        {
            std::ostringstream o;
            o << std::hex << v;
            return o.str();
        }

        // Finds every function the hooks need. Returns "" when the routing
        // functions (resolver, DoCommand) are found, else why not; scroll_why
        // says why the wheel's scroll can't be hooked ("" when it can).
        auto find_game_code(std::string& report, std::string& scroll_why) -> std::string
        {
            Finder f;
            if (f.primaries.empty() || !f.img.text_end) return "could not read the game's code";
            std::ostringstream log;
            auto note = [&](const char* name, uint32_t found, uint32_t known) {
                log << name << " " << hex32(found) << (found == known ? "" : " (moved since Nov 2026)") << "; ";
            };

            int64_t exec_team = property_offset(STR("/Script/ReadyOrNot.Default__SwatCommandWidget"), STR("ExecutionTeamType"));
            int64_t active_team = property_offset(STR("/Script/ReadyOrNot.Default__SwatCommandWidget"), STR("ActiveTeamType"));
            if (exec_team < 0 || active_team < 0) return "SwatCommandWidget's team properties not found";
            widget_team = static_cast<uint32_t>(active_team);

            // IsSWATTeamDead: the last call in its exec thunk.
            uint32_t dead_thunk = ufunction_rva(f, STR("/Script/ReadyOrNot.SWATManager:IsSWATTeamDead"));
            if (dead_thunk)
            {
                Body b = f.body(dead_thunk, 0x200);
                if (!b.calls.empty()) team_dead_rva = b.calls.back().target;
            }

            // DoCommand and the resolver.
            uint32_t do_thunk = ufunction_rva(f, STR("/Script/ReadyOrNot.SwatCommandWidget:DoCommand"));
            if (!do_thunk) return "SwatCommandWidget:DoCommand not found";
            std::vector<std::pair<uint32_t, uint32_t>> found;
            std::set<uint32_t> tried;
            for (auto& c : f.body(do_thunk, 0x800).calls)
            {
                if (!tried.insert(c.target).second) continue;
                Body t = f.body(c.target);
                if (t.calls.empty() || !f.looks_like_resolver(t.calls[0].target)) continue;
                if (!Finder::uses(t, exec_team)) continue;
                found.emplace_back(c.target, t.calls[0].target);
            }
            if (found.size() != 1) return "DoCommand not recognised (" + std::to_string(found.size()) + " candidates)";
            docommand_rva = found[0].first;
            resolver_rva = found[0].second;
            note("resolver", resolver_rva, KNOWN_RESOLVER);
            note("DoCommand", docommand_rva, KNOWN_DOCOMMAND);

            // The team scroll and set-team: among the resolver's callers.
            if (!team_dead_rva)
            {
                scroll_why = "IsSWATTeamDead not found";
            }
            else
            {
                note("IsSWATTeamDead", team_dead_rva, KNOWN_TEAM_DEAD);
                std::set<uint32_t> callers;
                const uint8_t* base = f.img.base;
                for (uint32_t off = f.img.text_begin; off + 5 <= f.img.text_end; ++off)
                {
                    if (base[off] != 0xE8) continue;
                    int32_t rel;
                    std::memcpy(&rel, base + off + 1, 4);
                    if (static_cast<int64_t>(off) + 5 + rel != resolver_rva) continue;
                    uint32_t start = f.start_of(off);
                    if (start) callers.insert(start);
                }
                auto is_set_team = [&](uint32_t rva) {
                    Body b = f.body(rva, 0x400);
                    return Finder::uses(b, active_team, false, false, 0x40) && Finder::uses(b, active_team + 1, true, false, 0x40) &&
                           Finder::calls_to(b, resolver_rva) && Finder::calls_to(b, team_dead_rva);
                };
                std::vector<std::pair<uint32_t, uint32_t>> scrolls;
                for (uint32_t c : callers)
                {
                    Body b = f.body(c);
                    if (b.calls.empty() || b.calls[0].target != resolver_rva) continue;
                    bool asks_all = false;
                    for (auto& call : b.calls)
                    {
                        if (call.target == team_dead_rva)
                        {
                            asks_all = call.dl == 5;
                            break;
                        }
                    }
                    if (!asks_all || !Finder::uses(b, active_team, true, true)) continue;
                    uint32_t set_team = 0;
                    std::set<uint32_t> seen;
                    for (auto& call : b.calls)
                    {
                        if (call.target == resolver_rva || call.target == team_dead_rva || !seen.insert(call.target).second) continue;
                        if (is_set_team(call.target))
                        {
                            set_team = call.target;
                            break;
                        }
                    }
                    if (set_team) scrolls.emplace_back(c, set_team);
                }
                if (scrolls.size() != 1)
                {
                    scroll_why = "the wheel's team scroll not recognised (" + std::to_string(scrolls.size()) + " candidates)";
                }
                else
                {
                    scroll_rva = scrolls[0].first;
                    set_team_rva = scrolls[0].second;
                    note("team scroll", scroll_rva, KNOWN_SCROLL);
                    note("set team", set_team_rva, KNOWN_SET_TEAM);
                }
            }
            report = log.str();
            return "";
        }

        // USWATManager::Initialize's vtable slot: the override whose first
        // call is the parent class's function in the same slot (Super::Initialize).
        auto initialize_slot(UObject* manager) -> int
        {
            UClass* cls = manager->GetClassPrivate();
            UClass* parent = cls ? cls->GetSuperClass() : nullptr;
            UObject* parent_cdo = parent ? parent->GetClassDefaultObject() : nullptr;
            if (!parent_cdo) return -1;
            Finder f;
            auto vt = *reinterpret_cast<void***>(manager);
            auto pvt = *reinterpret_cast<void***>(parent_cdo);
            auto matches = [&](int i) {
                uint32_t mine = f.rva_of(vt[i]), theirs = f.rva_of(pvt[i]);
                if (!mine || !theirs || mine == theirs) return false;
                Body b = f.body(mine, 0x200);
                return !b.calls.empty() && b.calls[0].target == theirs;
            };
            if (matches(KNOWN_INITIALIZE_SLOT)) return KNOWN_INITIALIZE_SLOT;
            for (int d = 1; d <= 16; ++d)
            {
                if (matches(KNOWN_INITIALIZE_SLOT - d)) return KNOWN_INITIALIZE_SLOT - d;
                if (matches(KNOWN_INITIALIZE_SLOT + d)) return KNOWN_INITIALIZE_SLOT + d;
            }
            return -1;
        }
    } // namespace route

    // RoNTAK_SquadInstall() -> "installed" | nil, why
    auto squad_install(const LuaMadeSimple::Lua& lua) -> int
    {
        if (route::installed)
        {
            lua.set_string("already installed");
            return 1;
        }
        std::string report, scroll_why;
        std::string why = route::find_game_code(report, scroll_why);
        if (!why.empty()) return fail(lua, why + " (game updated?); squad routing stays off");
        auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        route::resolver_detour = std::make_unique<PLH::x64Detour>(reinterpret_cast<uint64_t>(base + route::resolver_rva),
                                                                  reinterpret_cast<uint64_t>(&route::resolver_hook),
                                                                  &route::resolver_trampoline);
        if (!route::resolver_detour->hook()) return fail(lua, "could not hook the squad manager resolver");
        route::docommand_detour = std::make_unique<PLH::x64Detour>(reinterpret_cast<uint64_t>(base + route::docommand_rva),
                                                                   reinterpret_cast<uint64_t>(&route::docommand_hook),
                                                                   &route::docommand_trampoline);
        if (!route::docommand_detour->hook())
        {
            route::resolver_detour->unHook();
            return fail(lua, "could not hook the command wheel's DoCommand");
        }
        route::installed = true;
        route::game_base = base;
        // The wheel's team scroll (RED .. FULL ELEMENT): optional, the rest works without it.
        if (scroll_why.empty())
        {
            route::scroll_detour = std::make_unique<PLH::x64Detour>(reinterpret_cast<uint64_t>(base + route::scroll_rva),
                                                                    reinterpret_cast<uint64_t>(&route::scroll_hook),
                                                                    &route::scroll_trampoline);
            route::scroll_installed = route::scroll_detour->hook();
            if (!route::scroll_installed) scroll_why = "could not hook the wheel's team scroll";
        }
        lua.set_string(report + (route::scroll_installed ? "wheel scroll on" : "wheel scroll off: " + scroll_why));
        return 1;
    }

    // RoNTAK_SquadCreate(main_manager) -> new manager path | nil, error
    // A second USWATManager in the main one's world, initialised like the
    // game's (its setup, tick). Lua then keeps it referenced from the world
    // (ExtraReferencedObjects), so it lives exactly as long as the mission.
    auto squad_create(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto main_path = args.string("main_manager");
        if (!args.error.empty()) return fail(lua, args.error);
        UObject* main = find_object(main_path);
        if (!main) return fail(lua, "squad manager not found: " + main_path);
        FStaticConstructObjectParameters params{main->GetClassPrivate(), main->GetOuterPrivate()};
        UObject* manager = UObjectGlobals::StaticConstructObject(params);
        if (!manager) return fail(lua, "could not create a squad manager");
        // (An uninitialised manager is left to the garbage collector: Lua
        // doesn't keep it.)
        // Initialize(FSubsystemCollectionBase&): the engine part only sets the
        // initialised flag and the tick type; the collection isn't used.
        alignas(16) static uint8_t collection[0x200]{};
        int slot = route::initialize_slot(manager);
        if (slot < 0) return fail(lua, "the squad manager's Initialize not found (game updated?)");
        auto vtable = *reinterpret_cast<void***>(manager);
        using InitializeFn = void (*)(UObject*, void*);
        reinterpret_cast<InitializeFn>(vtable[slot])(manager, collection);
        lua.set_string(path_of(manager));
        return 1;
    }

    // RoNTAK_SquadSet(manager, members, group) -> true | nil, error
    //   manager: the call-ins' manager path ("" = none: routing off)
    //   members: comma-separated actor paths (their controllers are added)
    //   group:   0 main, 1 call-ins, 2 both, for the command wheel
    auto squad_set(const LuaMadeSimple::Lua& lua) -> int
    {
        Args args{lua};
        auto manager_path = args.string("manager");
        auto member_list = split(args.string("members"));
        int group = static_cast<int>(args.number("group"));
        if (!args.error.empty()) return fail(lua, args.error);
        UObject* manager = manager_path.empty() ? nullptr : find_object(manager_path);
        if (!manager_path.empty() && !manager) return fail(lua, "squad manager not found: " + manager_path);
        std::unordered_set<const void*> members;
        for (auto& path : member_list)
        {
            UObject* actor = find_object(path);
            if (!actor) continue;
            members.insert(actor);
            if (auto controller = actor->GetValuePtrByPropertyNameInChain<UObject*>(STR("Controller")))
            {
                if (*controller) members.insert(*controller);
            }
        }
        // The manager the game itself resolves in that world (see resolver_hook).
        route::main_manager = (manager && route::installed) ? reinterpret_cast<route::ResolverFn>(route::resolver_trampoline)(manager) : nullptr;
        route::element_manager = route::main_manager ? manager : nullptr;
        if (route::element_manager) members.insert(route::element_manager); // its own calls
        route::members = std::move(members);
        route::group = (group >= 0 && group <= 2) ? group : 0;
        lua.set_bool(true);
        return 1;
    }

    // RoNTAK_SquadStatus() -> "installed=1 manager=1 members=4 group=1 redirects=N commands=N"
    auto squad_status(const LuaMadeSimple::Lua& lua) -> int
    {
        std::ostringstream o;
        o << "installed=" << route::installed << " manager=" << (route::element_manager != nullptr)
          << " members=" << route::members.size() << " group=" << route::group
          << " redirects=" << route::redirects << " commands=" << route::commands
          << " wheel_scroll=" << route::scroll_installed << " scrolls=" << route::scrolls;
        lua.set_string(o.str());
        return 1;
    }

    // RoNTAK_SquadGroup() -> the group the wheel commands now (0 RED / BLUE,
    // 1 GREEN / YELLOW, 2 FULL ELEMENT): the wheel's scroll changes it too.
    auto squad_group(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_integer(route::group);
        return 1;
    }

    auto register_functions(const LuaMadeSimple::Lua& lua) -> void
    {
        lua.register_function("RoNTAK_NativeVersion", &native_version);
        lua.register_function("RoNTAK_BeginSpawn", &begin_spawn);
        lua.register_function("RoNTAK_FinishSpawn", &finish_spawn);
        lua.register_function("RoNTAK_AppendObject", &append_object);
        lua.register_function("RoNTAK_ArrayCount", &array_count);
        lua.register_function("RoNTAK_CreateWidget", &create_widget);
        lua.register_function("RoNTAK_DumpCode", &dump_code);
        lua.register_function("RoNTAK_SquadInstall", &squad_install);
        lua.register_function("RoNTAK_SquadCreate", &squad_create);
        lua.register_function("RoNTAK_SquadSet", &squad_set);
        lua.register_function("RoNTAK_SquadStatus", &squad_status);
        lua.register_function("RoNTAK_SquadGroup", &squad_group);
    }
} // namespace

class RoNTAKNative : public CppUserModBase
{
  public:
    RoNTAKNative() : CppUserModBase()
    {
        ModName = STR("RoNTAKNative");
        ModVersion = STR("0.7.0");
        ModDescription = STR("Native helpers for the RoNTAK mod");
        ModAuthors = STR("RoNTAK");
        Output::send<LogLevel::Verbose>(STR("[RoNTAKNative] loaded, version 0.7.0\n"));
    }

    ~RoNTAKNative() override = default;

    auto on_lua_start(StringViewType mod_name,
                      LuaMadeSimple::Lua& lua,
                      LuaMadeSimple::Lua& main_lua,
                      LuaMadeSimple::Lua& async_lua,
                      std::vector<LuaMadeSimple::Lua*>& hook_luas) -> void override
    {
        if (mod_name != LUA_MOD_NAME)
        {
            return;
        }
        register_functions(lua);
        register_functions(main_lua);
        register_functions(async_lua);
        for (auto* hook_lua : hook_luas)
        {
            register_functions(*hook_lua);
        }
        Output::send<LogLevel::Verbose>(STR("[RoNTAKNative] functions registered for the RoNTAK Lua mod\n"));
    }
};

#define RONTAK_NATIVE_API __declspec(dllexport)
extern "C"
{
    RONTAK_NATIVE_API CppUserModBase* start_mod()
    {
        return new RoNTAKNative();
    }

    RONTAK_NATIVE_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
