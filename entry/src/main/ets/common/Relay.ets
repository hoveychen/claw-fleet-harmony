import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { deriveKeys, isSealed, openString, sealString, SealedBox } from './RelayCrypto';
import { SessionInfo } from '../models/Types';

/// Persistent WebSocket client for fleet-relay — the native ArkTS peer of
/// mobile-web/src/relay.ts. Speaks the relay envelope (auth / msg / agent_status)
/// and the Fleet business frames sealed inside `msg.payload`
/// (decision_created / decision_resolved / sessions / answer / req / reply); see
/// claw-fleet-core/src/mobile_relay.rs.
///
/// Encryption is opaque here: every `msg` payload is a sealed `{enc:"box"}`
/// envelope handled via RelayCrypto.sealString/openString. We advertise
/// `supportsGzip:false`, so the desktop never gzips (it compresses only when
/// EVERY live client opts in), and this client never needs to inflate — a gzip
/// optimisation can come later without touching the wire contract.

const DOMAIN = 0x0000;
const TAG = 'fleet';

const REQUEST_TIMEOUT_MS = 15000;
const HELLO_INTERVAL_MS = 15000;
const MAX_RECONNECT_MS = 15000;

/// ArkTS bans untyped object literals (`{}`) and object literals for `Record`
/// types, so we use an empty class instance wherever a "no data" / "no params"
/// placeholder object is needed on the wire.
class EmptyObj {}

/// Self-description this device announces so it appears in the desktop's device
/// list. Mirrors mobile-web's DeviceInfo.
export interface DeviceInfo {
  clientId: string;
  label: string;
  platform: string;
  pushSubscribed: boolean;
  supportsGzip: boolean;
  supportsBinary: boolean;
}

export interface RelayHandlers {
  onStatus?: (connected: boolean) => void;
  onAgentOnline?: (online: boolean) => void;
  onDecisionCreated?: (kind: string, request: Object) => void;
  onDecisionResolved?: (kind: string, id: string) => void;
  onSessions?: (sessions: SessionInfo[]) => void;
  onAuthError?: (message: string) => void;
}

// ── Wire frames (declared as interfaces so JSON.parse casts are typed) ─────────

interface InboundFrame {
  type?: string;
  agent_online?: boolean;
  online?: boolean;
  message?: string;
  payload?: SealedPayload;
}

interface SealedPayload {
  enc?: string;
  iv?: string;
  ct?: string;
  z?: boolean;
}

interface BusinessPayload {
  event?: string;
  kind?: string;
  id?: string;
  request?: Object;
  sessions?: SessionInfo[];
  req_id?: string;
  ok?: boolean;
  data?: Object;
  error?: string;
}

interface AuthFrame {
  type: string;
  role: string;
  secret: string;
}

interface MsgFrame {
  type: string;
  payload: SealedBox;
}

interface PendingEntry {
  resolve: (v: Object) => void;
  // Typed as Object (not Error): ArkTS's arkts-no-structural-typing rejects
  // passing a RelayRequestError to an `(e: Error)` param, but every value IS-A
  // Object nominally, so this is always assignable. The rejected value is still
  // a real Error subclass at runtime (instanceof Error holds).
  reject: (e: Object) => void;
  timer: number;
}

/// A failed `request`, tagged with whether the desktop actually rejected it
/// (`remote:true`) or the reply just never arrived (`remote:false`).
export class RelayRequestError extends Error {
  remote: boolean;

  constructor(message: string, remote: boolean) {
    super(message);
    this.name = 'RelayRequestError';
    this.remote = remote;
  }
}

function toWsUrl(relayUrl: string): string {
  let base = relayUrl.replace(/\/+$/, '');
  if (base.startsWith('https://')) {
    base = 'wss://' + base.substring('https://'.length);
  } else if (base.startsWith('http://')) {
    base = 'ws://' + base.substring('http://'.length);
  }
  return base + '/ws';
}

export class RelayClient {
  private relayUrl: string;
  private secret: string;
  private handlers: RelayHandlers;
  private deviceInfoProvider?: () => DeviceInfo;
  private ws: webSocket.WebSocket | null = null;
  private helloTimer: number = -1;
  private reqSeq = 0;
  // Per-instance prefix so req_ids never collide across devices sharing a
  // channel (the relay broadcasts every reply to all clients).
  private reqPrefix: string = util.generateRandomUUID(true);
  private pending: Map<string, PendingEntry> = new Map<string, PendingEntry>();
  private reconnectDelay = 1000;
  private closed = false;
  private authed = false;
  private channelToken?: string;
  private encKey?: Uint8Array;
  private keysReady?: Promise<void>;

  constructor(relayUrl: string, secret: string, handlers: RelayHandlers,
    deviceInfoProvider?: () => DeviceInfo) {
    this.relayUrl = relayUrl;
    this.secret = secret;
    this.handlers = handlers;
    this.deviceInfoProvider = deviceInfoProvider;
  }

  get isAuthed(): boolean {
    return this.authed;
  }

  /// Derive (once) the channel token and AES key from the pairing secret.
  private ensureKeys(): Promise<void> {
    let ready = this.keysReady;
    if (!ready) {
      ready = deriveKeys(this.secret).then((k) => {
        this.channelToken = k.channelToken;
        this.encKey = k.encKey;
      });
      this.keysReady = ready;
    }
    return ready;
  }

  connect(): void {
    this.closed = false;
    this.open();
  }

  close(): void {
    this.closed = true;
    this.sayGoodbye();
    this.stopHello();
    if (this.ws) {
      this.ws.close((_e: BusinessError, _ok: boolean) => {});
      this.ws = null;
    }
  }

  /// Best-effort "I'm leaving" so the desktop drops this device promptly.
  sayGoodbye(): void {
    const info = this.deviceInfoProvider?.();
    if (info) {
      this.sendPayloadEvent('client_bye', info.clientId, undefined);
    }
  }

  private startHello(): void {
    this.sendHello();
    this.stopHello();
    this.helloTimer = setInterval(() => this.sendHello(), HELLO_INTERVAL_MS);
  }

  private stopHello(): void {
    if (this.helloTimer !== -1) {
      clearInterval(this.helloTimer);
      this.helloTimer = -1;
    }
  }

  private sendHello(): void {
    const info = this.deviceInfoProvider?.();
    if (info) {
      // client_hello carries the full DeviceInfo; sealAndSend handles the JSON.
      void this.sealAndSend(helloPayload(info));
    }
  }

  private open(): void {
    if (this.closed) {
      return;
    }
    // Keys must exist before we auth: the `auth` frame carries channelToken.
    this.ensureKeys().then(() => {
      if (this.closed) {
        return;
      }
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      this.authed = false;

      ws.on('open', (_err: BusinessError, _value: Object) => {
        const token = this.channelToken ?? '';
        const auth: AuthFrame = { type: 'auth', role: 'client', secret: token };
        ws.send(JSON.stringify(auth), (_e: BusinessError, _ok: boolean) => {});
      });

      ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
        if (typeof value !== 'string') {
          return;
        }
        let frame: InboundFrame;
        try {
          frame = JSON.parse(value) as InboundFrame;
        } catch (e) {
          return;
        }
        this.handleFrame(frame);
      });

      ws.on('close', (_err: BusinessError, _value: Object) => {
        this.onSocketClosed();
      });

      ws.on('error', (_err: BusinessError) => {
        if (this.ws) {
          this.ws.close((_e: BusinessError, _ok: boolean) => {});
        }
      });

      ws.connect(toWsUrl(this.relayUrl), (err: BusinessError, _ok: boolean) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'ws connect failed: %{public}s', JSON.stringify(err));
        }
      });
    });
  }

  private onSocketClosed(): void {
    const wasAuthed = this.authed;
    this.authed = false;
    this.stopHello();
    this.handlers.onStatus?.(false);
    this.failPending('连接已断开');
    this.ws = null;
    if (this.closed) {
      return;
    }
    const delay = wasAuthed ? 1000 : this.reconnectDelay;
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, MAX_RECONNECT_MS);
    setTimeout(() => this.open(), delay);
  }

  private handleFrame(frame: InboundFrame): void {
    switch (frame.type) {
      case 'authed':
        this.authed = true;
        this.reconnectDelay = 1000;
        this.handlers.onStatus?.(true);
        this.handlers.onAgentOnline?.(frame.agent_online === true);
        this.startHello();
        break;
      case 'agent_status':
        this.handlers.onAgentOnline?.(frame.online === true);
        break;
      case 'error':
        this.handlers.onAuthError?.(frame.message ?? '认证失败');
        break;
      case 'msg':
        if (frame.payload) {
          this.dispatchMsgPayload(frame.payload);
        }
        break;
      default:
        break; // notify frames are delivered out-of-band via Push Kit
    }
  }

  /// A `msg` payload is a sealed `{enc:"box",iv,ct}` envelope. Open it, then
  /// dispatch the JSON business payload. Anything not a well-formed sealed
  /// envelope from our paired desktop is dropped (the next snapshot self-heals).
  private dispatchMsgPayload(payload: SealedPayload): void {
    const iv = payload.iv;
    const ct = payload.ct;
    if (!isSealed(payload.enc, iv, ct) || iv === undefined || ct === undefined) {
      return;
    }
    if (payload.z === true) {
      // We advertise supportsGzip:false, so the desktop should never gzip.
      hilog.warn(DOMAIN, TAG, 'dropping unexpected gzipped payload (z:true)');
      return;
    }
    const ek = this.encKey;
    if (!ek) {
      return;
    }
    const sealed: SealedBox = { enc: 'box', iv, ct };
    openString(ek, sealed)
      .then((json: string) => {
        let biz: BusinessPayload;
        try {
          biz = JSON.parse(json) as BusinessPayload;
        } catch (e) {
          return;
        }
        this.handlePayload(biz);
      })
      .catch((_e: Object) => {
        // bad key / tampered / malformed — drop the frame
      });
  }

  private handlePayload(payload: BusinessPayload): void {
    switch (payload.event) {
      case 'decision_created':
        if (payload.request !== undefined) {
          this.handlers.onDecisionCreated?.(payload.kind ?? '', payload.request);
        }
        break;
      case 'decision_resolved':
        this.handlers.onDecisionResolved?.(payload.kind ?? '', payload.id ?? '');
        break;
      case 'sessions':
        this.handlers.onSessions?.(payload.sessions ?? []);
        break;
      case 'reply': {
        const reqId = payload.req_id ?? '';
        const entry = this.pending.get(reqId);
        if (!entry) {
          return;
        }
        this.pending.delete(reqId);
        clearTimeout(entry.timer);
        if (payload.ok === true) {
          entry.resolve(payload.data ?? new EmptyObj());
        } else {
          entry.reject(new RelayRequestError(payload.error ?? '请求失败', true));
        }
        break;
      }
      default:
        break;
    }
  }

  private sendRaw(frame: Object): boolean {
    const ws = this.ws;
    if (!ws) {
      return false;
    }
    ws.send(JSON.stringify(frame), (_e: BusinessError, _ok: boolean) => {});
    return true;
  }

  /// Seal a business payload (a JSON string) and send it as a `msg` frame.
  private async sealAndSend(payloadJson: string): Promise<void> {
    const ws = this.ws;
    if (!ws) {
      return;
    }
    await this.ensureKeys();
    const ek = this.encKey;
    if (!ek) {
      return;
    }
    const sealed = await sealString(ek, payloadJson);
    const frame: MsgFrame = { type: 'msg', payload: sealed };
    ws.send(JSON.stringify(frame), (_e: BusinessError, _ok: boolean) => {});
  }

  /// Fire-and-forget seal+send for a `{event, clientId}` payload (bye).
  private sendPayloadEvent(event: string, clientId: string, _unused?: Object): void {
    const byeFrame: ByePayload = { event, clientId };
    void this.sealAndSend(JSON.stringify(byeFrame));
  }

  /// Answer a decision — mirrors mobile_relay::handle_answer's shapes. `fields`
  /// is a JSON object serialised into the payload alongside {event,kind,id}.
  /// `payload` is a fully-formed answer envelope (a declared interface instance
  /// carrying {event:'answer', kind, id, …fields}); the decision views (P4) build
  /// the concrete shape. Kept as `Object` because ArkTS bans dynamic `Record`
  /// literals, so the merge happens on the caller side against a typed interface.
  answer(payload: Object): void {
    void this.sealAndSend(JSON.stringify(payload));
  }

  /// Data request to the agent (pending_snapshot / task_plans / …). `params` is
  /// a declared interface instance (never a `Record` literal — banned in ArkTS).
  request<T>(method: string, params?: Object, timeoutMs?: number): Promise<T> {
    this.reqSeq += 1;
    const reqId = `${this.reqPrefix}-${this.reqSeq}`;
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Object) => void) => {
      if (!this.ws) {
        reject(new RelayRequestError('尚未连接 relay', false));
        return;
      }
      const timer = setTimeout(() => {
        this.pending.delete(reqId);
        reject(new RelayRequestError('请求超时（桌面端可能离线）', false));
      }, timeoutMs ?? REQUEST_TIMEOUT_MS);
      const entry: PendingEntry = {
        resolve: (v: Object) => resolve(v as T),
        reject,
        timer,
      };
      this.pending.set(reqId, entry);
      const reqFrame: ReqPayload = { event: 'req', req_id: reqId, method, params: params ?? new EmptyObj() };
      this.sealAndSend(JSON.stringify(reqFrame)).catch((_e: Object) => {
        const pendingEntry = this.pending.get(reqId);
        if (!pendingEntry) {
          return;
        }
        this.pending.delete(reqId);
        clearTimeout(pendingEntry.timer);
        pendingEntry.reject(new RelayRequestError('尚未连接 relay', false));
      });
    });
  }

  private failPending(message: string): void {
    this.pending.forEach((entry: PendingEntry) => {
      clearTimeout(entry.timer);
      entry.reject(new RelayRequestError(message, false));
    });
    this.pending.clear();
  }
}

// ── Payload shapes for outbound frames (typed literals for ArkTS) ──────────────

interface HelloPayload {
  event: string;
  clientId: string;
  label: string;
  platform: string;
  pushSubscribed: boolean;
  supportsGzip: boolean;
  supportsBinary: boolean;
}

interface ByePayload {
  event: string;
  clientId: string;
}

interface ReqPayload {
  event: string;
  req_id: string;
  method: string;
  params: Object;
}

function helloPayload(info: DeviceInfo): string {
  const p: HelloPayload = {
    event: 'client_hello',
    clientId: info.clientId,
    label: info.label,
    platform: info.platform,
    pushSubscribed: info.pushSubscribed,
    supportsGzip: info.supportsGzip,
    supportsBinary: info.supportsBinary,
  };
  return JSON.stringify(p);
}
