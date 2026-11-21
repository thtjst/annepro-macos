/// Checksum used by the Anne Pro for custom lighting and layout payloads.
///
/// It is CRC-16/MODBUS: reflected polynomial 0xA001, initial value 0xFFFF, no final XOR.
/// The official Obins app (and the community ports of it) ship it as two 256-entry
/// lookup tables; this bitwise version produces identical results.
public enum CRC16 {
    public static func modbus<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}
