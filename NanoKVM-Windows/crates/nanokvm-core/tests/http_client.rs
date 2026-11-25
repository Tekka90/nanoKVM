use std::collections::HashMap;
use std::net::SocketAddr;

use nanokvm_core::{
    ClientConfig, CoreError, Credentials, LoginResult, NanoKvmClient, StaticIpRequest,
};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

#[derive(Debug)]
struct Request {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

struct Response {
    status: &'static str,
    headers: Vec<(&'static str, &'static str)>,
    body: String,
}

struct MockServer {
    address: SocketAddr,
    requests: mpsc::Receiver<Request>,
}

impl MockServer {
    async fn start(responses: Vec<Response>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (sender, requests) = mpsc::channel(responses.len());
        tokio::spawn(async move {
            for response in responses {
                let (mut stream, _) = listener.accept().await.unwrap();
                let request = read_request(&mut stream).await;
                sender.send(request).await.unwrap();
                let extra = response
                    .headers
                    .iter()
                    .map(|(name, value)| format!("{name}: {value}\r\n"))
                    .collect::<String>();
                let wire = format!(
                    "HTTP/1.1 {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n{}\r\n{}",
                    response.status,
                    response.body.len(),
                    extra,
                    response.body
                );
                stream.write_all(wire.as_bytes()).await.unwrap();
            }
        });
        Self { address, requests }
    }

    fn client(&self) -> NanoKvmClient {
        NanoKvmClient::new(ClientConfig::new(format!("http://{}", self.address))).unwrap()
    }

    async fn next_request(&mut self) -> Request {
        self.requests.recv().await.unwrap()
    }
}

async fn read_request(stream: &mut tokio::net::TcpStream) -> Request {
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 4096];
    loop {
        let count = stream.read(&mut buffer).await.unwrap();
        assert!(count > 0, "connection closed before request headers");
        bytes.extend_from_slice(&buffer[..count]);
        if bytes.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    let header_end = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .unwrap()
        + 4;
    let head = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next().unwrap().split(' ');
    let method = request_line.next().unwrap().to_owned();
    let path = request_line.next().unwrap().to_owned();
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.to_ascii_lowercase(), value.trim().to_owned());
        }
    }
    let content_length = headers
        .get("content-length")
        .map(|value| value.parse::<usize>().unwrap())
        .unwrap_or(0);
    while bytes.len() - header_end < content_length {
        let count = stream.read(&mut buffer).await.unwrap();
        assert!(count > 0, "connection closed during request body");
        bytes.extend_from_slice(&buffer[..count]);
    }
    Request {
        method,
        path,
        headers,
        body: bytes[header_end..header_end + content_length].to_vec(),
    }
}

fn success(data: Value) -> Response {
    Response {
        status: "200 OK",
        headers: vec![],
        body: json!({"code": 0, "msg": "", "data": data}).to_string(),
    }
}

fn json_body(request: &Request) -> Value {
    serde_json::from_slice(&request.body).unwrap()
}

#[tokio::test]
async fn adds_api_prefix_security_headers_and_decodes_envelope() {
    let mut server = MockServer::start(vec![success(json!({"name": "NanoKVM"}))]).await;
    let client = server.client();
    client.set_token("secret-test-token");

    let result: Value = client.get("/vm/info").await.unwrap();
    let request = server.next_request().await;

    assert_eq!(request.method, "GET");
    assert_eq!(request.path, "/api/vm/info");
    assert_eq!(
        request.headers["origin"],
        format!("http://{}", server.address)
    );
    assert_eq!(
        request.headers["referer"],
        format!("http://{}/", server.address)
    );
    assert_eq!(
        request.headers["cookie"],
        "nano-kvm-token=secret-test-token"
    );
    assert_eq!(result, json!({"name": "NanoKVM"}));
}

#[tokio::test]
async fn surfaces_api_and_http_errors() {
    let server = MockServer::start(vec![
        Response {
            status: "200 OK",
            headers: vec![],
            body: json!({"code": 17, "msg": "denied"}).to_string(),
        },
        Response {
            status: "503 Service Unavailable",
            headers: vec![],
            body: "maintenance".into(),
        },
    ])
    .await;
    let client = server.client();

    let api = client.get::<Value>("/vm/info").await.unwrap_err();
    assert_eq!(
        api,
        CoreError::Api {
            code: 17,
            message: "denied".into()
        }
    );
    let http = client.get::<Value>("/vm/info").await.unwrap_err();
    assert_eq!(
        http,
        CoreError::HttpStatus {
            status: 503,
            body: "maintenance".into()
        }
    );
}

#[tokio::test]
async fn login_exchanges_two_factor_challenge_and_stores_cookie() {
    let mut server = MockServer::start(vec![
        success(json!({"requires2FA": true, "challenge": "challenge-123"})),
        Response {
            status: "200 OK",
            headers: vec![("set-cookie", "nano-kvm-token=fresh-token; Path=/; HttpOnly")],
            body: json!({"code": 0, "msg": "", "data": {"token": "fresh-token"}}).to_string(),
        },
        success(json!({"ok": true})),
    ])
    .await;
    let client = server.client();
    let credentials = Credentials::new("admin", "test-password").unwrap();

    let first = client.login(&credentials).await.unwrap();
    assert_eq!(
        first,
        LoginResult::RequiresTwoFactor {
            challenge: "challenge-123".into()
        }
    );
    let first_request = server.next_request().await;
    assert_eq!(first_request.path, "/api/auth/login");
    assert_eq!(
        json_body(&first_request),
        json!({"username": "admin", "password": "test-password"})
    );

    let second = client
        .complete_two_factor_login(&nanokvm_core::TwoFactorVerifyRequest {
            challenge: "challenge-123".into(),
            code: "123456".into(),
        })
        .await
        .unwrap();
    assert_eq!(second, LoginResult::Authenticated);
    let second_request = server.next_request().await;
    assert_eq!(second_request.path, "/api/auth/login");
    assert_eq!(
        json_body(&second_request),
        json!({"challenge": "challenge-123", "code": "123456"})
    );

    let _: Value = client.get("/vm/status").await.unwrap();
    let third_request = server.next_request().await;
    assert_eq!(
        third_request.headers["cookie"],
        "nano-kvm-token=fresh-token"
    );
}

#[tokio::test]
async fn preserves_exact_toggle_spellings() {
    let mut server = MockServer::start(vec![success(json!({})), success(json!({}))]).await;
    let client = server.client();
    client.set_low_power(true).await.unwrap();
    client
        .set_static_ip(&StaticIpRequest {
            enabled: true,
            ip: "192.0.2.5".into(),
        })
        .await
        .unwrap();

    let low_power = server.next_request().await;
    let static_ip = server.next_request().await;
    assert_eq!(json_body(&low_power), json!({"enable": true}));
    assert_eq!(
        json_body(&static_ip),
        json!({
            "enabled": true,
            "ip": "192.0.2.5"
        })
    );
}

#[tokio::test]
async fn uses_exact_routes_methods_and_upload_forms() {
    let mut server = MockServer::start(vec![success(json!({})), success(json!({}))]).await;
    let client = server.client();
    client.delete_image("disk.img").await.unwrap();
    client
        .storage_upload_chunk(
            nanokvm_core::ChunkMetadata {
                upload_id: "upload-1".into(),
                file_name: "disk.img".into(),
                chunk_size: 5,
                chunk_index: 1,
                total_chunks: 2,
            },
            b"bytes".to_vec(),
        )
        .await
        .unwrap();

    let delete = server.next_request().await;
    let chunk = server.next_request().await;
    assert_eq!(
        (delete.method.as_str(), delete.path.as_str()),
        ("POST", "/api/storage/image/delete")
    );
    assert_eq!(json_body(&delete), json!({"file": "disk.img"}));
    assert_eq!(
        chunk.path,
        "/api/storage/image/upload?uploadId=upload-1&filename=disk.img&chunkSize=5&chunkIndex=1&totalChunks=2"
    );
    assert_eq!(chunk.headers["content-type"], "application/octet-stream");
    assert_eq!(chunk.body, b"bytes");
}

#[tokio::test]
async fn serializes_stream_and_tailscale_command_fields() {
    let mut server = MockServer::start(vec![success(json!({})), success(json!({}))]).await;
    let client = server.client();

    client.set_stream_mode("h265-direct".into()).await.unwrap();
    client
        .tailscale_action("exit-node-enable".into())
        .await
        .unwrap();

    let encoder = server.next_request().await;
    let action = server.next_request().await;
    assert_eq!(encoder.path, "/api/stream/mode");
    assert_eq!(json_body(&encoder), json!({"mode": "h265-direct"}));
    assert_eq!(action.path, "/api/extensions/tailscale/exit-node-enable");
    assert!(action.body.is_empty());
}

#[test]
fn builds_authenticated_secure_websocket_endpoint() {
    let client = NanoKvmClient::new(ClientConfig::new("https://kvm.local/api")).unwrap();
    client.set_token("token");

    let endpoint = client.websocket_endpoint("/stream/h265/direct").unwrap();
    assert_eq!(endpoint.url, "wss://kvm.local/api/stream/h265/direct");
    assert_eq!(endpoint.origin, "https://kvm.local");
    assert_eq!(endpoint.cookie.as_deref(), Some("nano-kvm-token=token"));
}
