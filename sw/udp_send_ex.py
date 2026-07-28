import socket

FPGA_IP = "169.254.1.100"
FPGA_PORT = 1234

payloads = [
    b"A",
    b"Hello",
    b"FPGA UDP",
    b"Short test payload",
    b"The quick brown fox jumps",
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    b"Testing variable length UDP payloads from Python.",
    b"1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    b"This payload is intentionally longer to exercise the receive path.",
    b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!@#$"
]

for payload in payloads:
    assert len(payload) <= 70

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

def print_payload_lengths():
    print("Payload Lengths:")
    for i, payload in enumerate(payloads):
        print(f"Payload {i}: {len(payload)} bytes")

def send_all_payloads():
    for i, payload in enumerate(payloads):
        sock.sendto(payload, (FPGA_IP, FPGA_PORT))
        print(f"Sent payload {i}: {len(payload)} bytes")


if __name__ == "__main__":
    #print_payload_lengths()
    send_all_payloads()
    sock.close()