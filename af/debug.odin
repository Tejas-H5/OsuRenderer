package af

import "core:fmt"
import "core:mem"
import "core:runtime"

LogSeverity :: enum {
    Debug,
    Info,
    Warning,
    FatalError,
}

debug_log :: proc(format: string, msg: ..any, loc := #caller_location) {
    debug_log_internal(format, ..msg, loc = loc, severity = .Debug)
}

debug_info :: proc(format: string, msg: ..any, loc := #caller_location) {
    debug_log_internal(format, ..msg, loc = loc, severity = .Info)
}

debug_warning :: proc(format: string, msg: ..any, loc := #caller_location) {
    debug_log_internal(format, ..msg, loc = loc, severity = .Warning)
}

debug_fatal_error :: proc(format: string, msg: ..any, loc := #caller_location) {
    debug_log_internal(format, ..msg, loc = loc, severity = .FatalError)

    panic("Exiting due to fatal error", loc = loc)
}

@(private)
debug_log_internal :: proc(
    format: string,
    msg: ..any,
    loc := #caller_location,
    severity := LogSeverity.Debug,
) {
    severity_str: string
    switch severity {
    case .Debug:
        severity_str = "DEBUG"
    case .Info:
        severity_str = "INFO"
    case .Warning:
        severity_str = "WARNING"
    case .FatalError:
        severity_str = "FATAL ERROR"
    }

    // this specific format when printed in the VSCode terminal will create a hyperlink to this log location
    fmt.printf("[%s] %s:%d:%d - \t", severity_str, loc.file_path, loc.line, loc.column)
    fmt.printf(format, ..msg)
    fmt.printf("\n")
}
