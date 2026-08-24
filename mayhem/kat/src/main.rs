// mayhem/kat/src/main.rs — Known-Answer-Test probe for mayhem/test.sh.
//
// A small, DYNAMICALLY LINKED (default rustc behavior on x86_64-unknown-linux-gnu — no
// cgo-style trick needed, unlike Go) standalone binary that asserts EXACT computed values from
// FIXED inputs through the real `protobuf` crate wire-format code — the same
// encode/decode path every fuzz target in this integration exercises. This is the load-bearing
// oracle: `cargo test` alone is a forbidden sole oracle (a statically-linked Go/Rust test binary
// can survive the gate's LD_PRELOAD sabotage shim while asserting nothing meaningful), so this
// probe's plain stdout is what mayhem/test.sh actually greps for exact expected strings.
//
// Any assertion failure below panics -> non-zero exit -> no "_OK"/"_PASS" markers printed ->
// test.sh's grep fails loudly. Under the sabotage shim (LD_PRELOAD _exit(0)s this binary's own
// process before main() runs, since /mayhem/kat is not a system path) stdout stays EMPTY, which
// is exactly the behavioral difference the gate proves.

use protobuf::descriptor::FileDescriptorProto;
use protobuf::CodedInputStream;
use protobuf::CodedOutputStream;
use protobuf::Message;

fn main() {
    // KAT 1: raw varint wire-format primitive (core to every parse in this library).
    // 300 encodes as two little-endian-base128 bytes: 0xAC (172 = 0x2C | continuation),
    // 0x02 -- i.e. (0x02 << 7) | 0x2C == 300. This is the textbook varint(300) fixture.
    let mut buf = Vec::new();
    {
        let mut os = CodedOutputStream::vec(&mut buf);
        os.write_raw_varint32(300).expect("write_raw_varint32 failed");
        os.flush().expect("flush failed");
    }
    assert_eq!(
        buf,
        vec![0xAC, 0x02],
        "varint(300) encoding mismatch: got {:?}",
        buf
    );
    let decoded = {
        let mut is = CodedInputStream::from_bytes(&buf);
        is.read_raw_varint32().expect("read_raw_varint32 failed")
    };
    assert_eq!(decoded, 300, "varint decode mismatch: got {}", decoded);
    println!("KAT1_VARINT_OK 300->[0xAC,0x02]->300");

    // KAT 2: a REAL generated protobuf message (FileDescriptorProto, compiled into the
    // `protobuf` crate itself to describe descriptor.proto -- no codegen/protoc needed here)
    // round-trips a hand-encoded single string field byte-for-byte through
    // Message::parse_from_bytes / write_to_bytes, the exact API every fuzz_target_* in
    // test-crates/protobuf-fuzz calls.
    //   field 1 (name, string), wire type 2 (length-delimited):
    //   tag = (1 << 3) | 2 = 0x0A, len = 9, "kat.proto"
    let bytes: &[u8] = &[0x0A, 0x09, b'k', b'a', b't', b'.', b'p', b'r', b'o', b't', b'o'];
    let msg = FileDescriptorProto::parse_from_bytes(bytes).expect("parse_from_bytes failed");
    assert_eq!(
        msg.name(),
        "kat.proto",
        "decoded name field mismatch: got {:?}",
        msg.name()
    );
    let out = msg.write_to_bytes().expect("write_to_bytes failed");
    assert_eq!(
        out, bytes,
        "re-serialized bytes mismatch: got {:?} want {:?}",
        out, bytes
    );
    println!("KAT2_MESSAGE_OK name=kat.proto roundtrip_bytes={}", out.len());

    // KAT 3: malformed input must be REJECTED, not silently accepted -- proves the parser
    // actually validates rather than just echoing bytes back. A truncated length-delimited
    // field (claims 9 bytes of payload, only 3 are present) must error.
    let truncated: &[u8] = &[0x0A, 0x09, b'k', b'a', b't'];
    match FileDescriptorProto::parse_from_bytes(truncated) {
        Err(_) => println!("KAT3_REJECT_OK truncated_input_rejected"),
        Ok(m) => panic!("KAT3_REJECT_FAIL: truncated input was accepted as {:?}", m),
    }

    println!("KAT_ALL_PASS");
}
