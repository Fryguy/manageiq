## 2025-05-14 - [Unsafe method invocation in template substitution]
**Vulnerability:** Unrestricted use of `send(method)` where `method` is derived from user-configurable template variables (e.g., in SNMP trap options).
**Learning:** The application allowed arbitrary method calls on model instances through `${Object.method}` syntax in policy actions. This could be exploited to trigger side-effect heavy methods like `destroy`.
**Prevention:** Always use an allowlist of safe attributes and virtual columns when dynamically invoking methods on objects from user-supplied strings. Use `public_send` instead of `send`.

## 2025-05-14 - [Misuse of manual quoting in non-shell command execution]
**Vulnerability:** Manual interpolation of single quotes around arguments passed to `Open3.capture3` with multiple arguments.
**Learning:** Developers often mistakenly add quotes to arguments thinking they are protecting against shell injection, even when using APIs that do not invoke a shell. This actually causes the literal quotes to be passed as part of the argument value, which can then cause downstream injection if the receiving script uses the argument unsafely.
**Prevention:** Trust the OS/API to handle argument separation when using non-shell execution methods. Pass arguments as separate elements in an array or argument list without manual quoting.
