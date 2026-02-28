use super::traits::RuntimeAdapter;
use std::path::{Path, PathBuf};

/// Locate a usable shell for command execution.
///
/// On Unix, `sh` is always available. On Windows, `sh.exe` may not be on
/// PATH when launched from PowerShell/CMD — Git installs it under
/// `C:\Program Files\Git\usr\bin\` which isn't on the default system PATH.
/// Falls back to `cmd.exe /C` if no `sh` can be found.
#[cfg(windows)]
fn find_shell() -> (PathBuf, Vec<&'static str>) {
    if std::process::Command::new("sh")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
    {
        return (PathBuf::from("sh"), vec!["-c"]);
    }

    for candidate in &[
        r"C:\Program Files\Git\usr\bin\sh.exe",
        r"C:\Program Files (x86)\Git\usr\bin\sh.exe",
    ] {
        let p = Path::new(candidate);
        if p.exists() {
            return (p.to_path_buf(), vec!["-c"]);
        }
    }

    (PathBuf::from("cmd"), vec!["/C"])
}

#[cfg(not(windows))]
fn find_shell() -> (PathBuf, Vec<&'static str>) {
    (PathBuf::from("sh"), vec!["-c"])
}

/// Native runtime — full access, runs on Mac/Linux/Docker/Raspberry Pi
pub struct NativeRuntime;

impl NativeRuntime {
    pub fn new() -> Self {
        Self
    }
}

impl RuntimeAdapter for NativeRuntime {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn name(&self) -> &str {
        "native"
    }

    fn has_shell_access(&self) -> bool {
        true
    }

    fn has_filesystem_access(&self) -> bool {
        true
    }

    fn storage_path(&self) -> PathBuf {
        directories::UserDirs::new().map_or_else(
            || PathBuf::from(".zeroclaw"),
            |u| u.home_dir().join(".zeroclaw"),
        )
    }

    fn supports_long_running(&self) -> bool {
        true
    }

    fn build_shell_command(
        &self,
        command: &str,
        workspace_dir: &Path,
    ) -> anyhow::Result<tokio::process::Command> {
        let (shell, prefix_args) = find_shell();
        let mut process = tokio::process::Command::new(shell);
        for arg in prefix_args {
            process.arg(arg);
        }
        process.arg(command).current_dir(workspace_dir);
        Ok(process)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_name() {
        assert_eq!(NativeRuntime::new().name(), "native");
    }

    #[test]
    fn native_has_shell_access() {
        assert!(NativeRuntime::new().has_shell_access());
    }

    #[test]
    fn native_has_filesystem_access() {
        assert!(NativeRuntime::new().has_filesystem_access());
    }

    #[test]
    fn native_supports_long_running() {
        assert!(NativeRuntime::new().supports_long_running());
    }

    #[test]
    fn native_memory_budget_unlimited() {
        assert_eq!(NativeRuntime::new().memory_budget(), 0);
    }

    #[test]
    fn native_storage_path_contains_zeroclaw() {
        let path = NativeRuntime::new().storage_path();
        assert!(path.to_string_lossy().contains("zeroclaw"));
    }

    #[test]
    fn native_builds_shell_command() {
        let cwd = std::env::temp_dir();
        let command = NativeRuntime::new()
            .build_shell_command("echo hello", &cwd)
            .unwrap();
        let debug = format!("{command:?}");
        assert!(debug.contains("echo hello"));
    }

    #[test]
    fn find_shell_returns_valid_shell() {
        let (shell, args) = find_shell();
        assert!(!args.is_empty(), "shell must have at least one prefix arg");
        let shell_str = shell.to_string_lossy();
        assert!(
            shell_str.contains("sh") || shell_str.contains("cmd"),
            "shell must be sh or cmd, got: {shell_str}"
        );
    }

    #[tokio::test]
    async fn native_shell_command_executes_echo() {
        let cwd = std::env::temp_dir();
        let mut cmd = NativeRuntime::new()
            .build_shell_command("echo shell_test_ok", &cwd)
            .unwrap();
        let output = cmd.output().await.expect("shell command should execute");
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("shell_test_ok"),
            "expected 'shell_test_ok' in output, got: {stdout}"
        );
    }
}
