// RoNTAK native mod (UE4SS C++ mod).
//
// Gives RoNTAK's Lua mod the few things Lua can't do safely. For now
// (groundwork) a single function that proves the native mod is loaded:
//   RoNTAK_NativeVersion() -> "0.1.0"
// Functions are registered into every Lua state of the "RoNTAK" Lua mod
// (main, async and the game-thread ones RoNTAK's tick runs in).

#include <string>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Mod/CppUserModBase.hpp>

using namespace RC;

namespace
{
    constexpr const char* NATIVE_VERSION = "0.1.0";
    constexpr const RC::CharType* LUA_MOD_NAME = STR("RoNTAK");

    auto native_version(const LuaMadeSimple::Lua& lua) -> int
    {
        lua.set_string(NATIVE_VERSION);
        return 1;
    }

    auto register_functions(const LuaMadeSimple::Lua& lua) -> void
    {
        lua.register_function("RoNTAK_NativeVersion", &native_version);
    }
} // namespace

class RoNTAKNative : public CppUserModBase
{
  public:
    RoNTAKNative() : CppUserModBase()
    {
        ModName = STR("RoNTAKNative");
        ModVersion = STR("0.1.0");
        ModDescription = STR("Native helpers for the RoNTAK mod");
        ModAuthors = STR("RoNTAK");
        Output::send<LogLevel::Verbose>(STR("[RoNTAKNative] loaded, version 0.1.0\n"));
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
