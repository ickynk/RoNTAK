// RoNTAK native mod (UE4SS C++ mod).
//
// Gives RoNTAK's Lua mod the few things Lua can't do safely on UE4SS 3.0.1:
//
//   RoNTAK_NativeVersion() -> "0.4.1"
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
//   RoNTAK_DumpCode(out_dir, seed_filters, classes, max_depth, max_mb,
//                   extra_rvas, xref_targets, field_disps)
//     Read-only: saves the game code around the wheel / squad functions for
//     reverse-engineering (see dump_code below).
//
// Objects are passed as object paths (obj:GetFullName() without the class
// name), never as raw addresses, and every one is looked up and type-checked
// here. Functions are registered into every Lua state of the "RoNTAK" Lua mod.

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
#include <set>
#include <sstream>
#include <unordered_set>

#include <Zydis/Zydis.h>

#define NOMINMAX
#include <Windows.h>

using namespace RC;
using namespace RC::Unreal;

namespace
{
    constexpr const char* NATIVE_VERSION = "0.4.1";
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

    auto register_functions(const LuaMadeSimple::Lua& lua) -> void
    {
        lua.register_function("RoNTAK_NativeVersion", &native_version);
        lua.register_function("RoNTAK_BeginSpawn", &begin_spawn);
        lua.register_function("RoNTAK_FinishSpawn", &finish_spawn);
        lua.register_function("RoNTAK_AppendObject", &append_object);
        lua.register_function("RoNTAK_ArrayCount", &array_count);
        lua.register_function("RoNTAK_CreateWidget", &create_widget);
        lua.register_function("RoNTAK_DumpCode", &dump_code);
    }
} // namespace

class RoNTAKNative : public CppUserModBase
{
  public:
    RoNTAKNative() : CppUserModBase()
    {
        ModName = STR("RoNTAKNative");
        ModVersion = STR("0.4.1");
        ModDescription = STR("Native helpers for the RoNTAK mod");
        ModAuthors = STR("RoNTAK");
        Output::send<LogLevel::Verbose>(STR("[RoNTAKNative] loaded, version 0.4.1\n"));
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
