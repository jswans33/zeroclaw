use crate::config::ToolProfile;
use std::collections::HashMap;
use std::sync::OnceLock;

pub trait ToolSelector: Send + Sync {
    fn select_tools(
        &self,
        message: &str,
        all_tools: &[&str],
        config_profile: &ToolProfile,
    ) -> Vec<String>;
}

const CORE_TOOLS: &[&str] = &["shell", "file_read"];

type KeywordMap = HashMap<&'static str, &'static [&'static str]>;

fn default_keyword_map() -> &'static KeywordMap {
    static MAP: OnceLock<KeywordMap> = OnceLock::new();
    MAP.get_or_init(|| {
        HashMap::from([
            (
                "file_read",
                ["file", "read", "cat", "show", "content", "code", "source"].as_slice(),
            ),
            (
                "file_write",
                ["write", "create", "save", "new file"].as_slice(),
            ),
            (
                "file_edit",
                [
                    "edit", "fix", "change", "modify", "update", "refactor", "bug",
                ]
                .as_slice(),
            ),
            (
                "memory_store",
                ["remember", "save", "store", "note"].as_slice(),
            ),
            (
                "memory_recall",
                ["recall", "remember", "what did", "history", "previous"].as_slice(),
            ),
            (
                "browser_open",
                ["browser", "webpage", "website", "url", "open page"].as_slice(),
            ),
            (
                "web_search",
                ["search", "google", "look up", "find online"].as_slice(),
            ),
            (
                "web_fetch",
                ["fetch", "download", "curl", "http get"].as_slice(),
            ),
            (
                "http_request",
                ["api", "request", "post", "endpoint", "rest"].as_slice(),
            ),
            (
                "glob_search",
                ["find file", "glob", "search files", "locate"].as_slice(),
            ),
            (
                "content_search",
                ["grep", "search content", "find in files", "pattern"].as_slice(),
            ),
            (
                "gpio_read",
                [
                    "gpio", "pin", "hardware", "sensor", "led", "arduino", "nucleo",
                ]
                .as_slice(),
            ),
            (
                "gpio_write",
                [
                    "gpio", "pin", "hardware", "led", "blink", "arduino", "nucleo",
                ]
                .as_slice(),
            ),
        ])
    })
}

pub struct KeywordToolSelector {
    tool_keywords: &'static KeywordMap,
}

impl Default for KeywordToolSelector {
    fn default() -> Self {
        Self {
            tool_keywords: default_keyword_map(),
        }
    }
}

impl ToolSelector for KeywordToolSelector {
    fn select_tools(
        &self,
        message: &str,
        all_tools: &[&str],
        _config_profile: &ToolProfile,
    ) -> Vec<String> {
        let lower = message.to_lowercase();
        let mut selected: Vec<String> = Vec::new();

        for core in CORE_TOOLS {
            if all_tools.contains(core) {
                selected.push(core.to_string());
            }
        }

        for tool_name in all_tools {
            if CORE_TOOLS.contains(tool_name) {
                continue;
            }
            if let Some(keywords) = self.tool_keywords.get(*tool_name) {
                let hit = keywords.iter().any(|kw| lower.contains(kw));
                if hit {
                    selected.push(tool_name.to_string());
                }
            } else {
                selected.push(tool_name.to_string());
            }
        }

        if selected.len() < 5 && message.len() > 100 {
            return all_tools.iter().map(|s| s.to_string()).collect();
        }

        selected
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ToolProfileName;

    #[test]
    fn keyword_scorer_excludes_irrelevant_tools() {
        let scorer = KeywordToolSelector::default();
        let all_tools = &[
            "shell",
            "file_read",
            "file_write",
            "file_edit",
            "memory_store",
            "memory_recall",
            "browser_open",
            "web_search",
            "web_fetch",
            "http_request",
            "gpio_read",
            "gpio_write",
        ];
        let selected = scorer.select_tools(
            "what time is it?",
            all_tools,
            &ToolProfile::Named(ToolProfileName::Full),
        );
        assert!(selected.contains(&"shell".to_string()));
        assert!(!selected.contains(&"browser_open".to_string()));
        assert!(!selected.contains(&"gpio_read".to_string()));
    }

    #[test]
    fn keyword_scorer_includes_file_tools_for_code_query() {
        let scorer = KeywordToolSelector::default();
        let all_tools = &[
            "shell",
            "file_read",
            "file_write",
            "file_edit",
            "browser_open",
        ];
        let selected = scorer.select_tools(
            "read the main.rs file and fix the bug",
            all_tools,
            &ToolProfile::Named(ToolProfileName::Full),
        );
        assert!(selected.contains(&"file_read".to_string()));
        assert!(selected.contains(&"file_edit".to_string()));
    }

    #[test]
    fn keyword_scorer_always_includes_core_tools() {
        let scorer = KeywordToolSelector::default();
        let all_tools = &["shell", "file_read", "gpio_write"];
        let selected = scorer.select_tools(
            "blink the LED",
            all_tools,
            &ToolProfile::Named(ToolProfileName::Full),
        );
        assert!(selected.contains(&"shell".to_string()));
        assert!(selected.contains(&"file_read".to_string()));
    }

    #[test]
    fn keyword_scorer_includes_unknown_tools_by_default() {
        let scorer = KeywordToolSelector::default();
        let all_tools = &["shell", "my_custom_mcp_tool"];
        let selected = scorer.select_tools(
            "do something",
            all_tools,
            &ToolProfile::Named(ToolProfileName::Full),
        );
        assert!(selected.contains(&"my_custom_mcp_tool".to_string()));
    }
}
