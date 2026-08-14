//! Minimal msgpack-RPC client for Neovim.
//!
//! Neovim ships the protocol, not a Rust client. This speaks it directly over a
//! unix socket: request `[0, msgid, method, params]`, response
//! `[1, msgid, error, result]`, notification `[2, method, params]`.
//!
//! Deliberately synchronous and dependency-light. Every call is a strict
//! request/response round trip with a read timeout, so a wedged or dead editor
//! surfaces as an error instead of hanging the agent.

use rmpv::decode::Error as DecodeError;
use rmpv::Value;
use std::io::{self, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Handles (Buffer/Window/Tabpage) arrive as msgpack EXT values. We never decode
/// them - they are passed straight back to Neovim as opaque tokens. That keeps us
/// immune to changes in how Neovim encodes handles.
pub type Handle = Value;

#[derive(Debug)]
pub enum Error {
    Connect { path: String, source: io::Error },
    Io(io::Error),
    Decode(String),
    /// Neovim accepted the connection but did not answer in time.
    Timeout { method: String, secs: u64 },
    /// Neovim closed the socket mid-conversation (usually it exited).
    Closed { method: String },
    /// Neovim returned an error in the response's error slot.
    Api { method: String, message: String },
    /// Protocol-level surprise (bad frame shape, unknown message type).
    Protocol(String),
    /// The session is reachable but too old for what was asked of it.
    Unsupported { feature: String, hint: String },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Connect { path, source } => {
                write!(f, "cannot connect to nvim socket {path}: {source}")
            }
            Error::Io(e) => write!(f, "io error talking to nvim: {e}"),
            Error::Decode(e) => write!(f, "cannot decode msgpack from nvim: {e}"),
            Error::Timeout { method, secs } => write!(
                f,
                "nvim did not respond to {method} within {secs}s.\n\
                 The editor is probably blocked waiting for input (a prompt, \
                 hit-enter message, or operator-pending state).\n\
                 Ask the user to return the editor to normal mode, then retry."
            ),
            Error::Closed { method } => write!(
                f,
                "nvim closed the connection during {method}.\n\
                 The session exited. Ask the user to restart it, or start one:\n\
                 \x20 nvim --headless --listen <socket> &"
            ),
            Error::Api { method, message } => write!(f, "nvim API error in {method}: {message}"),
            Error::Protocol(e) => write!(f, "msgpack-rpc protocol error: {e}"),
            Error::Unsupported { feature, hint } => {
                write!(f, "this nvim session does not support {feature}. {hint}")
            }
        }
    }
}

impl std::error::Error for Error {}

pub struct Nvim {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u32,
    timeout_secs: u64,
}

/// A read failure is usually a dead or wedged editor, not corrupt msgpack.
/// Reporting it as "cannot decode" sends the reader down the wrong path.
fn classify_read(e: DecodeError, method: &str, secs: u64) -> Error {
    let io_err = match &e {
        DecodeError::InvalidMarkerRead(io) | DecodeError::InvalidDataRead(io) => Some(io),
        DecodeError::DepthLimitExceeded => None,
    };
    if let Some(io) = io_err {
        match io.kind() {
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => {
                return Error::Timeout {
                    method: method.to_string(),
                    secs,
                }
            }
            io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset => {
                return Error::Closed {
                    method: method.to_string(),
                }
            }
            _ => {}
        }
    }
    Error::Decode(e.to_string())
}

impl Nvim {
    pub fn connect(path: &str, timeout: Duration) -> Result<Self, Error> {
        let stream = UnixStream::connect(path).map_err(|source| Error::Connect {
            path: path.to_string(),
            source,
        })?;
        stream.set_read_timeout(Some(timeout)).map_err(Error::Io)?;
        stream.set_write_timeout(Some(timeout)).map_err(Error::Io)?;
        let writer = stream.try_clone().map_err(Error::Io)?;
        Ok(Nvim {
            reader: BufReader::new(stream),
            writer,
            next_id: 1,
            timeout_secs: timeout.as_secs().max(1),
        })
    }

    /// One request/response round trip.
    ///
    /// Notifications (type 2) and stale responses can be interleaved on the
    /// socket, so we read until we see the response matching our msgid rather
    /// than assuming the next frame is ours.
    pub fn call(&mut self, method: &str, params: Vec<Value>) -> Result<Value, Error> {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);

        let request = Value::Array(vec![
            Value::from(0),
            Value::from(id),
            Value::from(method),
            Value::Array(params),
        ]);
        rmpv::encode::write_value(&mut self.writer, &request)
            .map_err(|e| Error::Io(io::Error::other(e)))?;
        self.writer.flush().map_err(Error::Io)?;

        loop {
            let frame = rmpv::decode::read_value(&mut self.reader)
                .map_err(|e| classify_read(e, method, self.timeout_secs))?;
            let items = match &frame {
                Value::Array(items) => items,
                other => return Err(Error::Protocol(format!("expected array frame, got {other}"))),
            };
            match items.first().and_then(Value::as_u64) {
                // Notification - not ours, keep waiting.
                Some(2) => continue,
                Some(1) => {}
                other => {
                    return Err(Error::Protocol(format!(
                        "unexpected message type {other:?}"
                    )))
                }
            }
            if items.len() != 4 {
                return Err(Error::Protocol(format!(
                    "response frame has {} items, expected 4",
                    items.len()
                )));
            }
            if items[1].as_u64() != Some(id as u64) {
                // Response to a request that timed out earlier; discard.
                continue;
            }
            if !items[2].is_nil() {
                return Err(Error::Api {
                    method: method.to_string(),
                    message: describe_api_error(&items[2]),
                });
            }
            return Ok(items[3].clone());
        }
    }

    /// `nvim_call_function` - the escape hatch for vimscript builtins that have
    /// no dedicated API function (`getqflist`, `setqflist`, `fnameescape`, ...).
    pub fn call_function(&mut self, name: &str, args: Vec<Value>) -> Result<Value, Error> {
        self.call(
            "nvim_call_function",
            vec![Value::from(name), Value::Array(args)],
        )
    }
}

/// Neovim errors arrive as `[type_code, "message"]`.
fn describe_api_error(value: &Value) -> String {
    if let Value::Array(parts) = value {
        if let Some(msg) = parts.get(1).and_then(Value::as_str) {
            return msg.to_string();
        }
    }
    value.to_string()
}
