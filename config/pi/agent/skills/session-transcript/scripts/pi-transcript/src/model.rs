use serde::Deserialize;
use serde_json::Value;

/// First line of every session file.
#[derive(Debug, Clone, Deserialize)]
pub struct Header {
    pub id: String,
    #[serde(default)]
    pub timestamp: String,
    #[serde(default)]
    pub cwd: String,
}

/// A single non-header line. Deliberately flat and permissive: every field is
/// optional so that entry types written by older pi versions still parse and
/// still contribute their `id`/`parentId` to the tree.
#[derive(Debug, Clone, Deserialize)]
pub struct Entry {
    #[serde(rename = "type", default)]
    pub kind: String,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(rename = "parentId", default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub timestamp: Option<String>,

    // type = "message"
    #[serde(default)]
    pub message: Option<Message>,

    // type = "thinking_level_change"
    #[serde(rename = "thinkingLevel", default)]
    pub thinking_level: Option<String>,

    // type = "model_change"
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(rename = "modelId", default)]
    pub model_id: Option<String>,

    // type = "compaction" / "branch_summary"
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(rename = "tokensBefore", default)]
    pub tokens_before: Option<u64>,
    #[serde(rename = "fromId", default)]
    pub from_id: Option<String>,

    // type = "custom" / "custom_message"
    #[serde(rename = "customType", default)]
    pub custom_type: Option<String>,
    #[serde(default)]
    pub content: Option<Content>,
    #[serde(default)]
    pub display: Option<bool>,

    // type = "label"
    #[serde(default)]
    pub label: Option<String>,
    #[serde(rename = "targetId", default)]
    pub target_id: Option<String>,

    // type = "session_info"
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "role")]
pub enum Message {
    #[serde(rename = "user")]
    User {
        #[serde(default)]
        content: Content,
    },
    #[serde(rename = "assistant")]
    Assistant {
        #[serde(default)]
        content: Content,
        #[serde(rename = "stopReason", default)]
        stop_reason: Option<String>,
        #[serde(rename = "errorMessage", default)]
        error_message: Option<String>,
    },
    #[serde(rename = "toolResult")]
    ToolResult {
        #[serde(rename = "toolName", default)]
        tool_name: Option<String>,
        #[serde(default)]
        content: Content,
        #[serde(rename = "isError", default)]
        is_error: bool,
    },
    #[serde(rename = "bashExecution")]
    BashExecution {
        #[serde(default)]
        command: String,
        #[serde(default)]
        output: String,
        #[serde(rename = "exitCode", default)]
        exit_code: Option<i64>,
    },
    /// Any role written by a pi version we do not model.
    #[serde(other)]
    Other,
}

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(untagged)]
pub enum Content {
    Text(String),
    Blocks(Vec<Block>),
    Other(Value),
    #[default]
    Empty,
}

/// Content blocks. Note what is *not* modelled: `thinkingSignature`,
/// `textSignature`, `thoughtSignature` and image `data` are all dropped on
/// parse, which is where most of a transcript's bulk lives.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum Block {
    #[serde(rename = "text")]
    Text {
        #[serde(default)]
        text: String,
    },
    #[serde(rename = "thinking")]
    Thinking {
        #[serde(default)]
        thinking: String,
        #[serde(default)]
        redacted: Option<bool>,
    },
    #[serde(rename = "toolCall")]
    ToolCall {
        #[serde(default)]
        name: String,
        #[serde(default)]
        arguments: Value,
    },
    #[serde(rename = "image")]
    Image {
        #[serde(rename = "mimeType", default)]
        mime_type: Option<String>,
    },
    #[serde(other)]
    Other,
}

impl Content {
    /// Concatenated plain text of the content, ignoring thinking/tool blocks.
    pub fn plain_text(&self) -> String {
        match self {
            Content::Text(s) => s.clone(),
            Content::Blocks(blocks) => {
                let mut out = String::new();
                for b in blocks {
                    if let Block::Text { text } = b {
                        if !out.is_empty() {
                            out.push('\n');
                        }
                        out.push_str(text);
                    }
                }
                out
            }
            Content::Other(v) => match v {
                Value::String(s) => s.clone(),
                Value::Null => String::new(),
                other => other.to_string(),
            },
            Content::Empty => String::new(),
        }
    }

    pub fn blocks(&self) -> Vec<Block> {
        match self {
            Content::Blocks(b) => b.clone(),
            Content::Text(s) => vec![Block::Text { text: s.clone() }],
            _ => vec![],
        }
    }
}
