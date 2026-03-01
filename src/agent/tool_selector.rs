use crate::config::ToolProfile;
use std::collections::HashMap;

pub trait ToolSelector: Send + Sync {
    fn select_tools(
        &self,
        message: &str,
        all_tools: &[&str],
        config_profile: &ToolProfile,
    ) -> Vec<String>;
}

const CORE_TOOLS: &[&str] = &["shell", "file_read"];

pub struct KeywordToolSelector {
    tool_keywords: HashMap<String, Vec<String>>,
}

impl Default for KeywordToolSelector {
    fn default() -> Self {
        let mut map = HashMap::new();
        map.insert(
            "file_read".into(),
            vec!["file", "read", "cat", "show", "content", "code", "source"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "file_write".into(),
            vec!["write", "create", "save", "new file"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "file_edit".into(),
            vec!["edit", "fix", "change", "modify", "update", "refactor", "bug"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "memory_store".into(),
            vec!["remember", "save", "store", "note"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "memory_recall".into(),
            vec!["recall", "remember", "what did", "history", "previous"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "browser_open".into(),
            vec!["browser", "webpage", "website", "url", "open page"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "web_search".into(),
            vec!["search", "google", "look up", "find online"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "web_fetch".into(),
            vec!["fetch", "download", "curl", "http get"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "http_request".into(),
            vec!["api", "request", "post", "endpoint", "rest"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "glob_search".into(),
            vec!["find file", "glob", "search files", "locate"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "content_search".into(),
            vec!["grep", "search content", "find in files", "pattern"]
                .into_iter()
                .map(String::from)
                .collect(),
        );
        map.insert(
            "gpio_read".into(),
            vec![
                "gpio", "pin", "hardware", "sensor", "led", "arduino", "nucleo",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
        );
        map.insert(
            "gpio_write".into(),
            vec![
                "gpio", "pin", "hardware", "led", "blink", "arduino", "nucleo",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
        );
        Self { tool_keywords: map }
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
            if selected.contains(&tool_name.to_string()) {
                continue;
            }
            if let Some(keywords) = self.tool_keywords.get(*tool_name) {
                let score = keywords
                    .iter()
                    .filter(|kw| lower.contains(kw.as_str()))
                    .count();
                if score > 0 {
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
