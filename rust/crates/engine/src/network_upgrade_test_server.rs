//! Loopback-only gRPC fixture for submission and fee-policy tests.

use prost::Message;
use std::{
    convert::Infallible,
    future::{ready, Ready},
    marker::PhantomData,
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    task::{Context, Poll},
};
use tonic::{
    body::Body,
    codec::{Codec, DecodeBuf, Decoder, EncodeBuf, Encoder},
    codegen::{http, BoxFuture, Service},
    server::{NamedService, UnaryService},
    Request, Response, Status,
};
use zcash_client_backend::proto::service::{
    compact_tx_streamer_client::CompactTxStreamerClient, BlockId, ChainSpec, Empty, LightdInfo,
    RawTransaction, SendResponse,
};

pub(crate) struct State {
    pub chain: Mutex<String>,
    pub tip: AtomicU32,
    pub fail_tip: AtomicBool,
    pub submission_count: AtomicUsize,
    pub stall_submission: AtomicBool,
    pub submission_started: tokio::sync::Notify,
    pub release_submission: tokio::sync::Notify,
    pub standard_fee: AtomicU64,
    pub estimator_version: AtomicU32,
    pub fee_error_code: AtomicI32,
    pub fee_request_count: AtomicUsize,
    pub after_tip_read: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
}

pub(crate) struct Server {
    pub client: CompactTxStreamerClient<tonic::transport::Channel>,
    pub state: Arc<State>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub(crate) async fn start(chain: &str, tip: u32) -> Server {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let state = Arc::new(State {
        chain: Mutex::new(chain.into()),
        tip: AtomicU32::new(tip),
        fail_tip: AtomicBool::new(false),
        submission_count: AtomicUsize::new(0),
        stall_submission: AtomicBool::new(false),
        submission_started: tokio::sync::Notify::new(),
        release_submission: tokio::sync::Notify::new(),
        standard_fee: AtomicU64::new(5000),
        estimator_version: AtomicU32::new(0),
        fee_error_code: AtomicI32::new(0),
        fee_request_count: AtomicUsize::new(0),
        after_tip_read: Mutex::new(None),
    });
    let service = RpcService(state.clone());
    let task = tokio::spawn(async move {
        tonic::transport::Server::builder()
            .add_service(service)
            .serve_with_incoming(tonic::transport::server::TcpIncoming::from(listener))
            .await
            .unwrap();
    });
    let channel = tonic::transport::Endpoint::from_shared(format!("http://{address}"))
        .unwrap()
        .connect()
        .await
        .unwrap();
    let client = CompactTxStreamerClient::new(channel);
    Server {
        client,
        state,
        task,
    }
}

#[derive(Clone)]
struct RpcService(Arc<State>);
impl NamedService for RpcService {
    const NAME: &'static str = "cash.z.wallet.sdk.rpc.CompactTxStreamer";
}
impl Service<http::Request<Body>> for RpcService {
    type Response = http::Response<Body>;
    type Error = Infallible;
    type Future = BoxFuture<Self::Response, Self::Error>;
    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }
    fn call(&mut self, request: http::Request<Body>) -> Self::Future {
        let state = self.0.clone();
        match request.uri().path() {
            "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLightdInfo" => Box::pin(async move {
                let reply = Reply::<Empty, LightdInfo>::new(move |_| {
                    Ok(LightdInfo {
                        chain_name: state.chain.lock().unwrap().clone(),
                        block_height: state.tip.load(Ordering::SeqCst) as u64,
                        ..Default::default()
                    })
                });
                Ok(
                    tonic::server::Grpc::new(WireCodec::<LightdInfo, Empty>::default())
                        .unary(reply, request)
                        .await,
                )
            }),
            "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetLatestBlock" => Box::pin(async move {
                let reply = Reply::<ChainSpec, BlockId>::new(move |_| {
                    if state.fail_tip.load(Ordering::SeqCst) {
                        return Err(Status::unavailable("fresh tip unavailable"));
                    }
                    if let Some(callback) = state.after_tip_read.lock().unwrap().as_ref() {
                        callback();
                    }
                    Ok(BlockId {
                        height: state.tip.load(Ordering::SeqCst) as u64,
                        hash: vec![0; 32],
                    })
                });
                Ok(
                    tonic::server::Grpc::new(WireCodec::<BlockId, ChainSpec>::default())
                        .unary(reply, request)
                        .await,
                )
            }),
            "/cash.z.wallet.sdk.rpc.CompactTxStreamer/SendTransaction" => Box::pin(async move {
                Ok(
                    tonic::server::Grpc::new(WireCodec::<SendResponse, RawTransaction>::default())
                        .unary(SubmissionReply(state), request)
                        .await,
                )
            }),
            "/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetStandardFee" => Box::pin(async move {
                let reply = Reply::<Empty, StandardFee>::new(move |_| {
                    state.fee_request_count.fetch_add(1, Ordering::SeqCst);
                    let code = state.fee_error_code.load(Ordering::SeqCst);
                    if code != 0 {
                        return Err(Status::new(
                            tonic::Code::from_i32(code),
                            "configured fee RPC error",
                        ));
                    }
                    Ok(StandardFee {
                        fee_zat: state.standard_fee.load(Ordering::SeqCst),
                        estimator_version: state.estimator_version.load(Ordering::SeqCst),
                    })
                });
                Ok(
                    tonic::server::Grpc::new(WireCodec::<StandardFee, Empty>::default())
                        .unary(reply, request)
                        .await,
                )
            }),
            _ => Box::pin(async {
                Ok(http::Response::builder()
                    .status(200)
                    .header("grpc-status", "12")
                    .header("content-type", "application/grpc")
                    .body(Body::empty())
                    .unwrap())
            }),
        }
    }
}

struct SubmissionReply(Arc<State>);
impl UnaryService<RawTransaction> for SubmissionReply {
    type Response = SendResponse;
    type Future = BoxFuture<Response<SendResponse>, Status>;
    fn call(&mut self, _: Request<RawTransaction>) -> Self::Future {
        let state = self.0.clone();
        Box::pin(async move {
            state.submission_count.fetch_add(1, Ordering::SeqCst);
            state.submission_started.notify_one();
            if state.stall_submission.load(Ordering::SeqCst) {
                state.release_submission.notified().await;
            }
            Ok(Response::new(SendResponse {
                error_code: 0,
                error_message: String::new(),
            }))
        })
    }
}

#[derive(Clone, PartialEq, prost::Message)]
struct StandardFee {
    #[prost(uint64, tag = "1")]
    fee_zat: u64,
    #[prost(uint32, tag = "2")]
    estimator_version: u32,
}

struct Reply<Q, S> {
    answer: Box<dyn Fn(Q) -> Result<S, Status> + Send + Sync>,
}
impl<Q, S> Reply<Q, S> {
    fn new(f: impl Fn(Q) -> Result<S, Status> + Send + Sync + 'static) -> Self {
        Self {
            answer: Box::new(f),
        }
    }
}
impl<Q: Send + 'static, S: Send + 'static> UnaryService<Q> for Reply<Q, S> {
    type Response = S;
    type Future = Ready<Result<Response<S>, Status>>;
    fn call(&mut self, request: Request<Q>) -> Self::Future {
        ready((self.answer)(request.into_inner()).map(Response::new))
    }
}

struct WireCodec<E, D>(PhantomData<(E, D)>);
impl<E, D> Default for WireCodec<E, D> {
    fn default() -> Self {
        Self(PhantomData)
    }
}
struct WireEncoder<E>(PhantomData<E>);
struct WireDecoder<D>(PhantomData<D>);
impl<E: Message + Send + 'static, D: Message + Default + Send + 'static> Codec for WireCodec<E, D> {
    type Encode = E;
    type Decode = D;
    type Encoder = WireEncoder<E>;
    type Decoder = WireDecoder<D>;
    fn encoder(&mut self) -> Self::Encoder {
        WireEncoder(PhantomData)
    }
    fn decoder(&mut self) -> Self::Decoder {
        WireDecoder(PhantomData)
    }
}
impl<E: Message> Encoder for WireEncoder<E> {
    type Item = E;
    type Error = Status;
    fn encode(&mut self, item: E, dst: &mut EncodeBuf<'_>) -> Result<(), Status> {
        item.encode(dst)
            .map_err(|e| Status::internal(e.to_string()))
    }
}
impl<D: Message + Default> Decoder for WireDecoder<D> {
    type Item = D;
    type Error = Status;
    fn decode(&mut self, src: &mut DecodeBuf<'_>) -> Result<Option<D>, Status> {
        D::decode(src)
            .map(Some)
            .map_err(|e| Status::internal(e.to_string()))
    }
}
