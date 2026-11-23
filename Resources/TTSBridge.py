#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TTS 桥（App 内调用）

为什么存在（2026-09-23 血泪史）：
    Swift URLSessionWebSocketTask 在 **GUI App 进程里**连火山网关必败
    （-999 cancelled / 握手 -1011），同代码 CLI 进程就没事——抓包到头对比排除
    了 UA/ATS/代理/IPv6/限流/缓存，最终判定是 CFNetwork 在 GUI 进程下的某种
    环境差异，短期无解。Python websockets 客户端全环境可用，故 App 内改用
    子进程桥接：本脚本负责 WebSocket 合成。

用法（两套协议）：

    1) 经典 mp3 文件模式（兼容老路径，输出完整 mp3 文件）:
        python3 TTSBridge.py --text "…" --key K --resource seed-icl-2.0 \\
            --speaker S_Hv09M32g2 --format mp3 --out /tmp/x.mp3
       退出码 0 = 成功；非 0 = 失败（原因在 stderr 最后一行）。

    2) PCM 流式模式（2026-09-24 新增，**首字延迟 ~400ms**）:
        python3 TTSBridge.py --text "…" --key K --resource seed-icl-2.0 \\
            --speaker S_Hv09M32g2 --format pcm
       输出走 stdout 二进制流，协议：
         [4B magic "PCM\x01"]            流开始，告知 Swift 端准备好播放器
         [4B BE chunk_len][float32 LE]    每帧 PCM 数据（多次）
         [4B magic "PCM\x00"]            流结束
         [4B magic "PCM!"][utf8 msg]     错误（替代 stderr）
       退出码 0 = 成功；非 0 = 协议层错误。
"""
import argparse
import asyncio
import json
import sys
import uuid

URL = "wss://openspeech.bytedance.com/api/v3/tts/bidirection"

FULL_CLIENT_REQUEST = 0b0001
AUDIO_ONLY_RESPONSE = 0b1011
FULL_SERVER_RESPONSE = 0b1001
ERROR_INFORMATION = 0b1111
WITH_EVENT = 0b0100
JSON_SER = 0b0001

EV_START_CONN = 1
EV_START_SESS, EV_FINISH_SESS = 100, 102
EV_CONN_STARTED = 50
EV_SESS_FINISHED, EV_SESS_FAILED = 152, 153
EV_TASK_REQUEST = 200
EV_TTS_RESPONSE = 352

HDR = bytes([(1 << 4) | 1, (FULL_CLIENT_REQUEST << 4) | WITH_EVENT, (JSON_SER << 4) | 0, 0])

# PCM 流式 stdout 协议 magic
MAGIC_START = b"PCM\x01"   # 流开始
MAGIC_END = b"PCM\x00"     # 流结束（正常）
MAGIC_ERR = b"PCM!"        # 错误（4B + UTF-8 错误描述）


def optional(event, session_id=None):
    b = bytearray()
    if event:
        b.extend(event.to_bytes(4, "big", signed=True))
    if session_id is not None:
        s = session_id.encode()
        b.extend(len(s).to_bytes(4, "big", signed=True))
        b.extend(s)
    return bytes(b)


def make_payload(event, text="", speaker="", audio_format="mp3", sample_rate=24000):
    return json.dumps({
        "user": {"uid": "makingheralive"},
        "event": event,
        "namespace": "BidirectionalTTS",
        "req_params": {
            "text": text,
            "speaker": speaker,
            "audio_params": {"format": audio_format, "sample_rate": sample_rate},
            "additions": json.dumps({"max_length_to_filter_parenthesis": 100}),
        },
    }).encode()


def frame(event, session_id=None, payload=b"{}"):
    return HDR + optional(event, session_id) + len(payload).to_bytes(4, "big", signed=True) + payload


def parse(r: bytes):
    mt = r[1] >> 4
    flags = r[1] & 0x0F
    off = 4
    event = None
    if flags & WITH_EVENT:
        event = int.from_bytes(r[off:off + 4], "big", signed=True)
        off += 4
    if mt in (AUDIO_ONLY_RESPONSE, FULL_SERVER_RESPONSE) and event == EV_TTS_RESPONSE:
        ln = int.from_bytes(r[off:off + 4], "big", signed=True)
        off += 4 + ln
    payload = b""
    if mt in (AUDIO_ONLY_RESPONSE, FULL_SERVER_RESPONSE, ERROR_INFORMATION) and len(r) >= off + 4:
        ln = int.from_bytes(r[off:off + 4], "big", signed=True)
        if 0 < ln <= len(r) - off - 4:
            payload = r[off + 4:off + 4 + ln]
    return mt, event, payload


async def synth(text, key, resource, speaker, out, audio_format="mp3"):
    """经典 mp3 文件模式：等所有帧收齐一次性写盘"""
    import websockets
    h = {"X-Api-Key": key, "X-Api-Resource-Id": resource,
         "X-Api-Connect-Id": str(uuid.uuid4()), "User-Agent": "makingheralive-tts-bridge/1.0"}
    async with websockets.connect(URL, additional_headers=h, max_size=50 * 1024 * 1024) as ws:
        await ws.send(frame(EV_START_CONN, None, b"{}"))
        mt, ev, pl = parse(await asyncio.wait_for(ws.recv(), timeout=8))
        if ev != EV_CONN_STARTED:
            raise RuntimeError(f"建连被拒: {pl[:120]}")

        sid = str(uuid.uuid4())
        await ws.send(frame(EV_START_SESS, sid, make_payload(EV_START_SESS, speaker=speaker, audio_format=audio_format)))
        mt, ev, pl = parse(await asyncio.wait_for(ws.recv(), timeout=8))
        if ev == EV_SESS_FAILED:
            raise RuntimeError(f"会话开启失败: {pl[:120]}")

        await ws.send(frame(EV_TASK_REQUEST, sid, make_payload(EV_TASK_REQUEST, text=text, speaker=speaker, audio_format=audio_format)))
        await asyncio.sleep(0.2)
        await ws.send(frame(EV_FINISH_SESS, sid, b"{}"))

        audio = bytearray()
        while True:
            mt, ev, pl = parse(await asyncio.wait_for(ws.recv(), timeout=30))
            if mt == AUDIO_ONLY_RESPONSE and ev == EV_TTS_RESPONSE:
                if pl:
                    audio.extend(pl)
            elif mt == ERROR_INFORMATION:
                raise RuntimeError(f"服务端错误: {pl[:150]}")
            elif ev == EV_SESS_FINISHED:
                break
            elif ev == EV_SESS_FAILED:
                raise RuntimeError(f"会话失败: {pl[:150]}")
        if not audio:
            raise RuntimeError("没收到音频")
        with open(out, "wb") as f:
            f.write(bytes(audio))


async def synth_stream_pcm(text, key, resource, speaker):
    """PCM 流式模式：每收一个 PCM 帧立即通过 stdout 二进制协议推给 Swift 端

    协议（4 字节 magic 区分阶段）：
        MAGIC_START    流开始（Swift 端开始准备播放器，无需等待）
        [BE32 len][f32 × len/4]   每帧裸 PCM 数据（len 必须是 4 的倍数）
        MAGIC_END      流结束（Swift 端播放队列自然走完）
        MAGIC_ERR [msg]  错误（msg UTF-8 错误描述）
    """
    import websockets
    import time
    h = {"X-Api-Key": key, "X-Api-Resource-Id": resource,
         "X-Api-Connect-Id": str(uuid.uuid4()), "User-Agent": "makingheralive-tts-bridge/2.0"}
    out = sys.stdout.buffer
    out.write(MAGIC_START)
    out.flush()

    # ⭐ 诊断：记录每帧字节数 + 收帧间隔，用于推算真实采样率
    diag_frame_sizes = []
    diag_first_frame_at = None
    diag_last_frame_at = None
    diag_total_bytes = 0

    try:
        async with websockets.connect(URL, additional_headers=h, max_size=50 * 1024 * 1024) as ws:
            await ws.send(frame(EV_START_CONN, None, b"{}"))
            mt, ev, pl = parse(await asyncio.wait_for(ws.recv(), timeout=8))
            if ev != EV_CONN_STARTED:
                raise RuntimeError(f"建连被拒: {pl[:120]}")

            sid = str(uuid.uuid4())
            await ws.send(frame(EV_START_SESS, sid, make_payload(EV_START_SESS, speaker=speaker, audio_format="pcm")))
            mt, ev, pl = parse(await asyncio.wait_for(ws.recv(), timeout=8))
            if ev == EV_SESS_FAILED:
                raise RuntimeError(f"会话开启失败: {pl[:120]}")

            await ws.send(frame(EV_TASK_REQUEST, sid, make_payload(EV_TASK_REQUEST, text=text, speaker=speaker, audio_format="pcm")))
            await asyncio.sleep(0.2)
            await ws.send(frame(EV_FINISH_SESS, sid, b"{}"))

            got_audio = False
            while True:
                mt, ev, pl = parse(await asyncio.wait_for(ws.recv(), timeout=30))
                if mt == AUDIO_ONLY_RESPONSE and ev == EV_TTS_RESPONSE:
                    if pl:
                        got_audio = True
                        now = time.time()
                        if diag_first_frame_at is None:
                            diag_first_frame_at = now
                        diag_last_frame_at = now
                        diag_frame_sizes.append(len(pl))
                        diag_total_bytes += len(pl)
                        # 长度前缀 + 裸 PCM 字节
                        out.write(len(pl).to_bytes(4, "big"))
                        out.write(pl)
                        out.flush()
                elif mt == ERROR_INFORMATION:
                    raise RuntimeError(f"服务端错误: {pl[:150]}")
                elif ev == EV_SESS_FINISHED:
                    break
                elif ev == EV_SESS_FAILED:
                    raise RuntimeError(f"会话失败: {pl[:150]}")
            if not got_audio:
                raise RuntimeError("没收到音频")
            out.write(MAGIC_END)
            out.flush()

            # ⭐ 诊断 log（stderr，Swift 端可读）
            if diag_frame_sizes and diag_last_frame_at and diag_first_frame_at:
                duration_s = diag_last_frame_at - diag_first_frame_at
                avg_frame = sum(diag_frame_sizes) / len(diag_frame_sizes)
                # 估算采样率：如果帧间隔均匀，总时长 ≈ 帧数 × 帧字节 / (采样率 × 4)
                # 但我们不知道真实采样率，只能反推：假设播放时长 = duration_s
                # 采样率 = 总字节 / (4 × duration_s)
                estimated_sr = diag_total_bytes / (4 * duration_s) if duration_s > 0 else 0
                print(f"[PCM诊断] 帧数={len(diag_frame_sizes)} 总字节={diag_total_bytes} "
                      f"平均帧={avg_frame:.0f}B 收帧耗时={duration_s:.2f}s "
                      f"推算采样率≈{estimated_sr:.0f}Hz", file=sys.stderr)
    except Exception as e:
        try:
            out.write(MAGIC_ERR)
            out.write(str(e)[:300].encode("utf-8", errors="replace"))
            out.flush()
        except Exception:
            pass
        raise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--resource", default="seed-icl-2.0")
    ap.add_argument("--speaker", required=True)
    ap.add_argument("--format", default="mp3", choices=["mp3", "pcm"],
                    help="mp3=写到 --out；pcm=stdout 流式")
    ap.add_argument("--out", help="mp3 模式必填")
    a = ap.parse_args()

    try:
        if a.format == "mp3":
            if not a.out:
                raise RuntimeError("mp3 模式必须传 --out")
            asyncio.run(synth(a.text, a.key, a.resource, a.speaker, a.out, "mp3"))
            print("OK")
            sys.exit(0)
        else:  # pcm
            asyncio.run(synth_stream_pcm(a.text, a.key, a.resource, a.speaker))
            sys.exit(0)
    except Exception as e:
        print(str(e)[:300], file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()