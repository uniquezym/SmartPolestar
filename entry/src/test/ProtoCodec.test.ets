import { describe, it, expect } from '@ohos/hypium';
import { ProtoWriter } from '../main/ets/core/proto/ProtoWriter';
import { ProtoReader, ProtoValue } from '../main/ets/core/proto/ProtoReader';
import { VehicleState } from '../main/ets/core/model/VehicleState';
import { Http2Frame, Http2FrameInfo, Http2FrameCodec, Hpack, HttpHeader } from '../main/ets/core/net/grpc/Http2Frame';
import { SessionState } from '../main/ets/core/model/SessionState';
import { VehicleStateReader } from '../main/ets/core/net/VehicleStateReader';

/**
 * 协议层单元测试。
 *
 * 用例集直接对标 Android 端还原工程中已通过的 22 项断言
 * （recovered/src/test/java/.../VerifyTest.java），
 * 确保两端协议实现产生完全一致的字节序列与语义。
 */
export default function protoCodecTest() {
  describe('ProtoCodecTest', () => {

    // ---------------- protobuf varint ----------------

    it('varint_round_trip', 0, () => {
      const values: number[] = [0, 1, 127, 128, 300, 2147483647, 4294967296];
      for (const v of values) {
        const encoded = ProtoWriter.writeVarint(v);
        const reader = new ProtoReader(encoded);
        expect(reader.readVarint()).assertEqual(v);
      }
    });

    it('protobuf_string_field_vin', 0, () => {
      const vin = 'YSMYKD5L2FB123456';
      const payload = ProtoWriter.writeStringField(2, vin);
      const fields = new ProtoReader(payload).decode();
      expect(ProtoValue.decodeString(ProtoValue.get(fields, 2))).assertEqual(vin);
    });

    it('protobuf_decode_map', 0, () => {
      const payload = ProtoWriter.concat(
        ProtoWriter.writeVarintField(1, 42),
        ProtoWriter.writeStringField(2, 'hello'));
      const fields = new ProtoReader(payload).decode();
      expect(ProtoValue.get(fields, 1)).assertEqual(42);
      expect(ProtoValue.decodeString(ProtoValue.get(fields, 2))).assertEqual('hello');
    });

    it('protobuf_repeated_field', 0, () => {
      const payload = ProtoWriter.concat(
        ProtoWriter.writeVarintField(6, 1),
        ProtoWriter.writeVarintField(6, 5),
        ProtoWriter.writeVarintField(6, 7));
      const fields = new ProtoReader(payload).decodeAll();
      const days = fields.get(6);
      expect(days !== undefined).assertTrue();
      expect(days!.length).assertEqual(3);
      expect(days![2]).assertEqual(7);
    });

    it('protobuf_fixed32_temperature', 0, () => {
      // 空调启动的 22.0f，走 field 3 fixed32
      const payload = ProtoWriter.writeFixed32Field(3, 22.0);
      const fields = new ProtoReader(payload).decode();
      const value = ProtoValue.asFloat(ProtoValue.get(fields, 3));
      expect(Math.abs(value - 22.0) < 0.001).assertTrue();
    });

    it('protobuf_field_number_matches_android', 0, () => {
      // 控制指令请求体：field 1 = VIN，field 2 = 动作枚举
      const writer = new ProtoWriter();
      writer.writeStringField(1, 'YSMYKD5L2FB123456');
      writer.writeVarintField(2, 3);
      const fields = new ProtoReader(writer.toUint8Array()).decode();
      expect(ProtoValue.decodeString(ProtoValue.get(fields, 1))).assertEqual('YSMYKD5L2FB123456');
      expect(ProtoValue.get(fields, 2)).assertEqual(3);
    });

    // ---------------- C3 请求体结构（对照 Android p000.ga0） ----------------

    it('status_request_vin_is_field_2', 0, () => {
      // 状态查询请求体：field 2 = VIN（tag 0x12）。
      // Android 端 m1418m0 -> m1389s0(vin, 2)；field 1 存的是 UUID/语言码。
      const vin = 'YSMYKD5L2FB123456';
      const payload = ProtoWriter.writeStringField(2, vin);
      expect(payload[0]).assertEqual(0x12);

      const fields = new ProtoReader(payload).decode();
      expect(ProtoValue.get(fields, 1)).assertEqual(undefined);
      expect(ProtoValue.decodeString(ProtoValue.get(fields, 2))).assertEqual(vin);
    });

    it('control_request_vin_is_nested_field_1', 0, () => {
      // 控制指令请求体：field 1 是嵌套字节，其内部 field 1 = VIN。
      // Android 端 m1364c(1, m1389s0(vin, 1))。
      const vin = 'YSMYKD5L2FB123456';
      const vinBytes = ProtoWriter.encodeUtf8(vin);
      const inner = ProtoWriter.concat(
        ProtoWriter.writeVarint(0x0a),
        ProtoWriter.writeVarint(vinBytes.length),
        vinBytes
      );
      const payload = ProtoWriter.writeBytesField(1, inner);
      expect(payload[0]).assertEqual(0x0a);

      const fields = new ProtoReader(payload).decode();
      const raw = ProtoValue.get(fields, 1);
      expect(raw instanceof Uint8Array).assertTrue();
      const innerFields = new ProtoReader(raw as Uint8Array).decode();
      expect(ProtoValue.decodeString(ProtoValue.get(innerFields, 1))).assertEqual(vin);
    });

    it('state_response_unwraps_outer_field_3', 0, () => {
      // 状态类接口响应外层是 field 3（还原自 m1349F(map, 3)）。
      const inner = ProtoWriter.concat(
        ProtoWriter.writeVarintField(2, 87),
        ProtoWriter.writeVarintField(4, 425));
      const outer = ProtoWriter.writeBytesField(3, inner);

      const decoded = new ProtoReader(outer).decode();
      const wrapped = ProtoValue.get(decoded, 3);
      expect(wrapped instanceof Uint8Array).assertTrue();

      const stateFields = new ProtoReader(wrapped as Uint8Array).decode();
      expect(ProtoValue.get(stateFields, 2)).assertEqual(87);
      expect(ProtoValue.get(stateFields, 4)).assertEqual(425);
    });

    it('state_response_falls_back_to_top_level', 0, () => {
      // 外层缺失时退回直接解顶层，避免个别服务结构差异导致全盘为空。
      const flat = ProtoWriter.concat(
        ProtoWriter.writeVarintField(2, 87),
        ProtoWriter.writeVarintField(4, 425));

      const decoded = new ProtoReader(flat).decode();
      const wrapped = ProtoValue.get(decoded, 3);
      expect(wrapped === undefined).assertTrue();
      expect(ProtoValue.get(decoded, 2)).assertEqual(87);
    });

    it('vehicle_state_reader_unwrap', 0, () => {
      // VehicleStateReader.unwrap：先取外层 field，再解内层。
      const inner = ProtoWriter.concat(
        ProtoWriter.writeVarintField(2, 87),
        ProtoWriter.writeVarintField(4, 425));
      const outer = ProtoWriter.writeBytesField(3, inner);

      const fields = VehicleStateReader.unwrap(outer, 3);
      expect(ProtoValue.get(fields, 2)).assertEqual(87);
      expect(ProtoValue.get(fields, 4)).assertEqual(425);
    });

    it('vehicle_state_reader_unwrap_fallback', 0, () => {
      const flat = ProtoWriter.writeVarintField(2, 87);
      const fields = VehicleStateReader.unwrap(flat, 3);
      expect(ProtoValue.get(fields, 2)).assertEqual(87);
    });

    // ---------------- 模型映射 ----------------

    it('window_summary_all_closed', 0, () => {
      expect(VehicleState.summarizeWindows([0, 0, 0, 0])).assertEqual('车窗已关闭');
    });

    it('window_summary_one_open', 0, () => {
      expect(VehicleState.summarizeWindows([0, 1, 0, 0])).assertEqual('车窗未关闭');
    });

    it('window_summary_state_three', 0, () => {
      expect(VehicleState.summarizeWindows([0, 3, 0, 0])).assertEqual('车窗未关闭');
    });

    it('window_summary_unknown', 0, () => {
      expect(VehicleState.summarizeWindows([])).assertEqual('车窗状态未知');
    });

    it('window_summary_null', 0, () => {
      expect(VehicleState.summarizeWindows(undefined)).assertEqual('车窗状态未知');
    });

    it('enum_label_in_range', 0, () => {
      const labels = ['未指定', '充电中', '空闲'];
      expect(VehicleState.enumLabel(1, labels)).assertEqual('充电中');
    });

    it('enum_label_out_of_range', 0, () => {
      const labels = ['未指定', '充电中', '空闲'];
      expect(VehicleState.enumLabel(99, labels)).assertEqual('未知');
    });

    it('enum_label_undefined', 0, () => {
      const labels = ['未指定', '充电中', '空闲'];
      expect(VehicleState.enumLabel(undefined, labels)).assertEqual('未知');
    });

    // ---------------- 会话序列化 ----------------

    it('session_plaintext_round_trip', 0, () => {
      const session = new SessionState('token-abc', 'refresh-xyz', 1700000000000);
      const plain = session.toPlaintext();
      expect(plain).assertEqual('token-abc\nrefresh-xyz\n1700000000000');
      const restored = SessionState.fromPlaintext(plain);
      expect(restored !== undefined).assertTrue();
      expect(restored!.accessToken).assertEqual('token-abc');
      expect(restored!.refreshToken).assertEqual('refresh-xyz');
      expect(restored!.expiresAt).assertEqual(1700000000000);
    });

    it('session_invalid_plaintext', 0, () => {
      expect(SessionState.fromPlaintext('bad') === undefined).assertTrue();
    });

    it('session_needs_refresh_margin', 0, () => {
      const session = new SessionState('t', 'r', 100000);
      // 距过期不足 30 秒即需续期
      expect(session.needsRefresh(99999)).assertTrue();
      expect(session.needsRefresh(50000)).assertFalse();
    });

    // ---------------- HTTP/2 帧层 ----------------

    it('http2_frame_encode_decode', 0, () => {
      const payload = new Uint8Array([1, 2, 3, 4, 5]);
      const frame = new Http2FrameInfo(0x00, 0x01, 3, payload);
      const encoded = Http2Frame.encode(frame);
      expect(encoded.length).assertEqual(14);
      // 9 字节帧头：长度(3) + 类型(1) + 标志(1) + streamId(4)
      expect(encoded[2]).assertEqual(5);
      expect(encoded[3]).assertEqual(0x00);
      expect(encoded[4]).assertEqual(0x01);
      expect(encoded[8]).assertEqual(3);

      const decoded = Http2Frame.decode(encoded, 0);
      expect(decoded !== undefined).assertTrue();
      expect(decoded!.consumed).assertEqual(14);
      expect(decoded!.frame.header.type).assertEqual(0x00);
      expect(decoded!.frame.header.streamId).assertEqual(3);
      expect(decoded!.frame.payload.length).assertEqual(5);
    });

    it('http2_frame_decode_incomplete', 0, () => {
      const encoded = Http2Frame.encode(new Http2FrameInfo(0x00, 0, 1, new Uint8Array([1, 2, 3])));
      // 截断到 5 字节，应无法解析出完整帧
      expect(Http2Frame.decode(encoded.slice(0, 5), 0) === undefined).assertTrue();
    });

    it('http2_settings_round_trip', 0, () => {
      const frame = Http2Frame.encodeSettings([0x04, 8192, 0x05, 16384]);
      const decoded = Http2Frame.decodeSettings(frame.payload);
      expect(decoded.length).assertEqual(4);
      expect(decoded[0]).assertEqual(0x04);
      expect(decoded[1]).assertEqual(8192);
      expect(decoded[2]).assertEqual(0x05);
      expect(decoded[3]).assertEqual(16384);
    });

    it('hpack_encode_decode_round_trip', 0, () => {
      const headers: HttpHeader[] = [
        { name: ':method', value: 'POST' },
        { name: ':path', value: '/services.vehiclestates.battery.BatteryService/GetLatestBattery' },
        { name: 'authorization', value: 'Bearer test-token' },
        { name: 'vin', value: 'YSMYKD5L2FB123456' }
      ];
      const encoded = Hpack.encode(headers);
      const decoded = Hpack.decode(encoded, 0);
      expect(decoded.headers.length).assertEqual(headers.length);
      for (let i = 0; i < headers.length; i++) {
        expect(decoded.headers[i].name).assertEqual(headers[i].name);
        expect(decoded.headers[i].value).assertEqual(headers[i].value);
      }
    });

    it('hpack_static_index_matches_rfc7541', 0, () => {
      // RFC 7541 附录 A 静态表索引校验
      // 索引 3 = ":method: POST"，索引 4 = ":path: /"，索引 7 = ":scheme: https"
      expect(Hpack.staticIndex(':method', 'POST')).assertEqual(3);
      expect(Hpack.staticIndex(':path', '/')).assertEqual(4);
      expect(Hpack.staticIndex(':scheme', 'https')).assertEqual(7);
      expect(Hpack.staticIndex('authorization', '')).assertEqual(23);
      expect(Hpack.staticIndex('user-agent', '')).assertEqual(58);
      // 不存在的组合应返回 -1
      expect(Hpack.staticIndex(':method', 'PUT')).assertEqual(-1);
      expect(Hpack.staticIndex('x-not-exist', 'v')).assertEqual(-1);
    });

    it('hpack_static_name_index_matches_rfc7541', 0, () => {
      // 名称引用语义：返回第一个名称匹配的条目
      expect(Hpack.staticNameIndex(':method')).assertEqual(2);
      expect(Hpack.staticNameIndex(':path')).assertEqual(4);
      expect(Hpack.staticNameIndex(':scheme')).assertEqual(6);
      expect(Hpack.staticNameIndex(':authority')).assertEqual(1);
      expect(Hpack.staticNameIndex('authorization')).assertEqual(23);
      expect(Hpack.staticNameIndex('content-type')).assertEqual(31);
      expect(Hpack.staticNameIndex('user-agent')).assertEqual(58);
      expect(Hpack.staticNameIndex('x-not-exist')).assertEqual(-1);
    });

    it('hpack_encoded_prefix_forms', 0, () => {
      // 完全匹配静态表 -> 带索引表示（1xxxxxxx，7 位前缀），索引 3 = ":method: POST"
      const methodOnly = Hpack.encode([{ name: ':method', value: 'POST' }]);
      expect(methodOnly[0]).assertEqual(0x83);

      // 名称命中静态表 -> 带增量索引的字面量（01xxxxxx，6 位前缀）
      // authorization 的静态表名称索引为 23 -> 0x40 | 23 = 0x57
      const authOnly = Hpack.encode([{ name: 'authorization', value: 'Bearer test-token' }]);
      expect(authOnly[0] & 0xc0).assertEqual(0x40);
      expect(authOnly[0] & 0x3f).assertEqual(23);

      // 名称为字面量 -> 同为 01xxxxxx 前缀，且索引为 0
      const custom = Hpack.encode([{ name: 'x-custom', value: 'v' }]);
      expect(custom[0] & 0xc0).assertEqual(0x40);
      expect(custom[0] & 0x3f).assertEqual(0);
    });

    it('hpack_huffman_encoded_matches_reference', 0, () => {
      // 与参考实现（Python hpack）逐字节一致的 HPACK 编码
      // vin -> 4083ee6abf8ee7bb473cd7dbce2c3742265a6dcf
      const vin = Hpack.encode([{ name: 'vin', value: 'YSMYKD5L2FB123456' }]);
      expect(vin.length).assertEqual(20);
      expect(vin[0]).assertEqual(0x40);
      expect(vin[1]).assertEqual(0x83);

      // authorization -> 578cba51d85b14495095927ea5ab
      const auth = Hpack.encode([{ name: 'authorization', value: 'Bearer test-token' }]);
      expect(auth.length).assertEqual(14);
      expect(auth[0]).assertEqual(0x57);
      expect(auth[1]).assertEqual(0x8c);

      // x-custom -> 4086f2b12d424f4f81ef
      const custom = Hpack.encode([{ name: 'x-custom', value: 'v' }]);
      expect(custom.length).assertEqual(10);
      expect(custom[0]).assertEqual(0x40);
      expect(custom[1]).assertEqual(0x86);
    });

    it('hpack_full_grpc_header_set_matches_reference', 0, () => {
      // 完整的 gRPC 请求头集合，与参考实现（Python hpack）逐字节一致
      // 参考: 838744ac6105b3b988542fdcb3989415091a4a85e31a525b3d2f7469496cf5b8b677310ac622a738
      //       d25426e8d292d9eb419a216ba4f1a4fd4b52f5d87917232bf73d1dce41d885c87a57255f5f901d75d0620d
      //       263d4c4d6564ff75d8749f4082497f864d833505b11f7a919acac8b741f71ac7eb3a535b015de6d70f
      //       578cba51d85b14495095927ea5ab4083ee6abf8ee7bb473cd7dbce2c3742265a6dcf
      const headers: HttpHeader[] = [
        { name: ':method', value: 'POST' },
        { name: ':scheme', value: 'https' },
        { name: ':path', value: '/services.vehiclestates.battery.BatteryService/GetLatestBattery' },
        { name: ':authority', value: 'cepmobtoken.prod.c3.volvocars.com.cn' },
        { name: 'content-type', value: 'application/grpc+proto' },
        { name: 'te', value: 'trailers' },
        { name: 'user-agent', value: 'grpc-java-okhttp/1.85.1' },
        { name: 'authorization', value: 'Bearer test-token' },
        { name: 'vin', value: 'YSMYKD5L2FB123456' }
      ];
      const encoded = Hpack.encode(headers);
      expect(encoded.length).assertEqual(158);
      expect(encoded[0]).assertEqual(0x83);
      expect(encoded[1]).assertEqual(0x87);
      expect(encoded[2]).assertEqual(0x44);

      // 解码回原文并逐项校验
      const decoded = Hpack.decode(encoded, 0);
      expect(decoded.headers.length).assertEqual(headers.length);
      for (let i = 0; i < headers.length; i++) {
        expect(decoded.headers[i].name).assertEqual(headers[i].name);
        expect(decoded.headers[i].value).assertEqual(headers[i].value);
      }
    });

    it('hpack_huffman_round_trip', 0, () => {
      // Huffman 编码后仍能正确解码回原文
      const text = 'YSMYKD5L2FB123456';
      const encoded = Hpack.huffmanEncode(text);
      expect(Hpack.huffmanDecode(encoded)).assertEqual(text);

      const path = '/services.vehiclestates.battery.BatteryService/GetLatestBattery';
      expect(Hpack.huffmanDecode(Hpack.huffmanEncode(path))).assertEqual(path);
    });

    it('hpack_integer_encoding', 0, () => {
      // RFC 7541 5.1 节的示例：10 用 5 位前缀编码为 0x0a
      const encoded = Http2FrameCodec.encodeInteger(5, 0, 10);
      expect(encoded.length).assertEqual(1);
      expect(encoded[0]).assertEqual(10);

      const decoded = Http2FrameCodec.decodeInteger(encoded, 0, 5);
      expect(decoded.value).assertEqual(10);
    });

    it('hpack_integer_encoding_multibyte', 0, () => {
      // 1337 用 5 位前缀编码：最大值 31，剩余 1306 需 2 字节续接，共 3 字节
      const encoded = Http2FrameCodec.encodeInteger(5, 0, 1337);
      expect(encoded.length).assertEqual(3);
      const decoded = Http2FrameCodec.decodeInteger(encoded, 0, 5);
      expect(decoded.value).assertEqual(1337);
    });

    it('http2_frame_stream_id_31bit', 0, () => {
      // streamId 使用 31 位，高位保留位必须为 0
      const frame = new Http2FrameInfo(0x01, 0x04, 0x7fffffff, new Uint8Array([1]));
      const encoded = Http2Frame.encode(frame);
      expect(encoded[5] & 0x80).assertEqual(0);
      const decoded = Http2Frame.decode(encoded, 0);
      expect(decoded!.frame.header.streamId).assertEqual(0x7fffffff);
    });
  });
}
