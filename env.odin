package main

import "core:os"
import "core:path/filepath"

// TODO: update this if it doesn't work on your end
get_osu_dir :: proc() -> string {
    when ODIN_OS == .Windows {
        appdata_local := os.get_env("LOCALAPPDATA")
        defer delete(appdata_local)
        return filepath.join([]string{appdata_local, "osu!", "Songs"})
    }

    when ODIN_OS == .Linux {
        // NOTE: untested
        return "~/. local/share/osu"
    }

    return ""
}

OSU_DIR := get_osu_dir()
