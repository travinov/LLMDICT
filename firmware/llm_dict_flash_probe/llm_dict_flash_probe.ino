#include <Arduino.h>
#include <Adafruit_TinyUSB.h>

namespace {

bool probeReadOk = false;
alignas(4) uint8_t probeJedec[4] = {0, 0, 0, 0};

constexpr uint32_t kSckMask = 1UL << 21;
constexpr uint32_t kCsMask = 1UL << 25;
constexpr uint32_t kMosiMask = 1UL << 20;
constexpr uint32_t kMisoMask = 1UL << 24;
constexpr uint32_t kWpMask = 1UL << 22;
constexpr uint32_t kHoldMask = 1UL << 23;

uint8_t transferByte(uint8_t outgoing) {
  uint8_t incoming = 0;
  for (uint8_t bit = 0; bit < 8; ++bit) {
    NRF_P0->OUTCLR = kSckMask;
    if ((outgoing & 0x80) != 0) {
      NRF_P0->OUTSET = kMosiMask;
    } else {
      NRF_P0->OUTCLR = kMosiMask;
    }
    outgoing <<= 1;
    NRF_P0->OUTSET = kSckMask;
    incoming = static_cast<uint8_t>((incoming << 1) |
                                    ((NRF_P0->IN & kMisoMask) ? 1 : 0));
  }
  NRF_P0->OUTCLR = kSckMask;
  return incoming;
}

void sendCommand(uint8_t command) {
  NRF_P0->OUTCLR = kCsMask;
  transferByte(command);
  NRF_P0->OUTSET = kCsMask;
  delayMicroseconds(30);
}

void printProbeResult() {
  Serial.print("FLASH_PROBE:READ_OK=");
  Serial.println(probeReadOk ? "YES" : "NO");
  Serial.print("FLASH_PROBE:JEDEC=");
  for (size_t index = 0; index < 3; ++index) {
    if (probeJedec[index] < 0x10) {
      Serial.print('0');
    }
    Serial.print(probeJedec[index], HEX);
    if (index < 2) {
      Serial.print(':');
    }
  }
  Serial.println();
  Serial.println("FLASH_PROBE:DONE,NO_WRITE_NO_ERASE");
}

void runProbe() {
  Serial.println("FLASH_PROBE:INIT_START");
  Serial.flush();
  NRF_P0->DIRSET = kSckMask | kCsMask | kMosiMask | kWpMask | kHoldMask;
  NRF_P0->DIRCLR = kMisoMask;
  NRF_P0->PIN_CNF[24] =
      (GPIO_PIN_CNF_DIR_Input << GPIO_PIN_CNF_DIR_Pos) |
      (GPIO_PIN_CNF_INPUT_Connect << GPIO_PIN_CNF_INPUT_Pos) |
      (GPIO_PIN_CNF_PULL_Disabled << GPIO_PIN_CNF_PULL_Pos) |
      (GPIO_PIN_CNF_DRIVE_S0S1 << GPIO_PIN_CNF_DRIVE_Pos) |
      (GPIO_PIN_CNF_SENSE_Disabled << GPIO_PIN_CNF_SENSE_Pos);
  NRF_P0->OUTSET = kCsMask | kWpMask | kHoldMask;
  NRF_P0->OUTCLR = kSckMask | kMosiMask;
  delayMicroseconds(10);

  sendCommand(0x66);  // Reset enable.
  sendCommand(0x99);  // Reset.
  delayMicroseconds(100);
  sendCommand(0xAB);  // Release from deep power-down.
  delayMicroseconds(100);

  NRF_P0->OUTCLR = kCsMask;
  transferByte(0x9F);
  for (size_t index = 0; index < 3; ++index) {
    probeJedec[index] = transferByte(0x00);
  }
  NRF_P0->OUTSET = kCsMask;
  probeReadOk = true;
  printProbeResult();
}

}  // namespace

void setup() {
  Serial.begin(115200);
  const uint32_t waitStartedMs = millis();
  while (!Serial && millis() - waitStartedMs < 2500) {
    delay(10);
  }

  Serial.println("BOOT:LLM_DICT_FLASH_PROBE_V1");
  Serial.println("FLASH_PROBE:READ_ONLY,SEND_Q_TO_RUN");
}

void loop() {
  if (Serial.available() > 0) {
    bool shouldRun = false;
    while (Serial.available() > 0) {
      const char command = static_cast<char>(Serial.read());
      shouldRun = shouldRun || command == 'Q' || command == 'q';
    }
    if (shouldRun) {
      runProbe();
    } else {
      Serial.println("FLASH_PROBE:SEND_Q_TO_RUN");
    }
  }
  delay(10);
}
