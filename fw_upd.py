
import serial
import sys
import time

def flash_hex(port, baudrate, hex_file):
    print(f"Connecting to {port} at {baudrate} baud...")

    try:
        ser = serial.Serial(port, baudrate, timeout=1.0)
    except serial.SerialException as e:
        print(f"\nERROR: Could not open serial port '{port}'.")
        print(f"Reason: {e}")
        return False

    print("Serial port opened successfully.")
    time.sleep(2.0)

    try:
        with open(hex_file, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"\nERROR: HEX file not found: '{hex_file}'")
        ser.close()
        return False
    except OSError as e:
        print(f"\nERROR: Could not open HEX file '{hex_file}'.")
        print(f"Reason: {e}")
        ser.close()
        return False

    print(f"Sending {len(lines)} Intel HEX records over UART...")

    # Read initial bootloader header if available
    if ser.in_waiting:
        header = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
        print(f"[UART RX]: {header.strip()}")

    # Flush any lingering startup characters
    ser.reset_input_buffer()
    ack_supported = None
    rx_buf = ""

    for i, line in enumerate(lines):
        line_clean = line.strip()

        if not line_clean:
            continue

        try:
            ser.write((line_clean + '\r\n').encode('utf-8'))
            ser.flush()
        except serial.SerialException as e:
            print(f"\nERROR: UART communication failed at line {i+1}.")
            print(f"Reason: {e}")
            ser.close()
            return False

        # If we haven't determined whether target supports ACK, probe on the first record
        if ack_supported is None:
            start_probe = time.time()
            got_ack = False
            while time.time() - start_probe < 0.15:
                if ser.in_waiting:
                    chunk = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
                    rx_buf += chunk
                    if "ERROR" in rx_buf:
                        print(f"\n[UART ERROR at line {i+1}]: {rx_buf.strip()}")
                        ser.close()
                        return False
                    if '.' in rx_buf:
                        got_ack = True
                        rx_buf = rx_buf.replace('.', '', 1)
                        break
                time.sleep(0.002)

            if got_ack:
                ack_supported = True
                print("ACK protocol detected. Using handshake flow control.")
                sys.stdout.write(".")
                sys.stdout.flush()
            else:
                ack_supported = False
                print("No ACK detected. Using timed delay fallback.")
                time.sleep(0.005)
            continue

        # Handshake / ACK flow control
        if ack_supported:
            start_wait = time.time()
            got_ack = False

            while time.time() - start_wait < 2.0:
                if '.' in rx_buf:
                    got_ack = True
                    rx_buf = rx_buf.replace('.', '', 1)
                    break

                if ser.in_waiting:
                    chunk = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
                    rx_buf += chunk

                    if "ERROR" in rx_buf:
                        print(f"\n[UART ERROR at line {i+1}]: {rx_buf.strip()}")
                        ser.close()
                        return False

                    if '.' in rx_buf:
                        got_ack = True
                        rx_buf = rx_buf.replace('.', '', 1)
                        break
                else:
                    time.sleep(0.001)

            if not got_ack:
                print(f"\nERROR: Timeout waiting for ACK at line {i+1}.")
                ser.close()
                return False

            sys.stdout.write(".")
            sys.stdout.flush()

        else:
            # Fallback for bootloaders without ACK
            time.sleep(0.005)

            if ser.in_waiting:
                rx = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
                if "ERROR" in rx:
                    print(f"\n[UART ERROR at line {i+1}]: {rx.strip()}")
                    ser.close()
                    return False
                elif rx.strip():
                    print(f"[UART RX]: {rx.strip()}")

    print()
    time.sleep(0.2)

    if ser.in_waiting:
        rx = ser.read(ser.in_waiting).decode('utf-8', errors='ignore')
        rx_buf += rx

    if rx_buf.strip():
        print(f"[UART RX Final]: {rx_buf.strip()}")

    ser.close()
    print("\nFirmware transfer finished successfully!")
    return True


if __name__ == "__main__":
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB1"
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
    hex_path = sys.argv[3] if len(sys.argv) > 3 else "build/test/c/running_led/out.hex"

    flash_hex(port, baud, hex_path)
