#include <PDM.h>
#include <bluefruit.h>
#include <string.h>

namespace {

constexpr uint32_t kSerialBaud = 115200;
constexpr uint32_t kSerialWaitMs = 2500;
constexpr uint32_t kDebounceMs = 30;
constexpr uint32_t kStatusIntervalMs = 1000;
constexpr uint32_t kEraseTimeoutMs = 120000;
constexpr uint32_t kSampleRate = 16000;
constexpr uint16_t kChannels = 1;
constexpr uint16_t kBitsPerSample = 16;
constexpr uint32_t kBytesPerSecond =
    kSampleRate * kChannels * (kBitsPerSample / 8);
constexpr uint32_t kWavHeaderSize = 44;
constexpr uint32_t kPrototypeSeconds = 60;
constexpr uint32_t kExpectedFlashSize = 2UL * 1024UL * 1024UL;
constexpr uint32_t kPrototypeAudioLimit = kBytesPerSecond * kPrototypeSeconds;
constexpr uint32_t kExpectedJedecId = 0x856015;
constexpr uint8_t kPdmGain = 70;
constexpr uint8_t kButtonPin = D10;
constexpr size_t kPdmBufferBytes = 512;
constexpr size_t kRingSize = 8192;
constexpr size_t kRingMask = kRingSize - 1;
static_assert((kRingSize & kRingMask) == 0,
              "Audio ring size must be a power of two");

// The Sense Plus variant in Seeed nRF52 core 1.1.12 has stale QSPI indices,
// so the bundled driver addresses unrelated pins. Use the physical pins from
// Seeed's schematic/variant.cpp and keep every operation bounded to 2 MiB.
class RawSpiFlash {
 public:
  bool begin() {
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

    sendSimpleCommand(0x66);  // Reset enable.
    sendSimpleCommand(0x99);  // Reset.
    delayMicroseconds(100);
    sendSimpleCommand(0xAB);  // Release from deep power-down.
    delayMicroseconds(100);

    select();
    transfer(0x9F);
    jedecId_ = static_cast<uint32_t>(transfer(0x00)) << 16;
    jedecId_ |= static_cast<uint32_t>(transfer(0x00)) << 8;
    jedecId_ |= transfer(0x00);
    deselect();
    ready_ = jedecId_ == kExpectedJedecId;
    return ready_;
  }

  uint32_t getJEDECID() const { return jedecId_; }
  uint32_t size() const { return ready_ ? kExpectedFlashSize : 0; }

  bool isReady() {
    return ready_ && (readStatus() & 0x01) == 0;
  }

  bool waitUntilReady(uint32_t timeoutMs = 10000) {
    const uint32_t startedMs = millis();
    while (!isReady()) {
      if (millis() - startedMs >= timeoutMs) {
        return false;
      }
      yield();
    }
    return true;
  }

  bool eraseChip() {
    if (!ready_ || !waitUntilReady() || !writeEnable()) {
      return false;
    }
    sendSimpleCommand(0xC7);
    return true;
  }

  uint32_t readBuffer(uint32_t address, uint8_t* buffer, uint32_t length) {
    if (!ready_ || address > kExpectedFlashSize ||
        length > kExpectedFlashSize - address || !waitUntilReady()) {
      return 0;
    }

    select();
    transfer(0x03);
    sendAddress(address);
    for (uint32_t index = 0; index < length; ++index) {
      buffer[index] = transfer(0x00);
    }
    deselect();
    return length;
  }

  uint32_t writeBuffer(uint32_t address, const uint8_t* buffer,
                       uint32_t length) {
    if (!ready_ || address > kExpectedFlashSize ||
        length > kExpectedFlashSize - address) {
      return 0;
    }

    uint32_t written = 0;
    while (written < length) {
      const uint32_t pageLeft = 256 - (address & 0xFF);
      const uint32_t chunk = min(pageLeft, length - written);
      if (!pageProgram(address, buffer + written, chunk)) {
        break;
      }
      address += chunk;
      written += chunk;
    }
    return written;
  }

 private:
  static constexpr uint32_t kSckMask = 1UL << 21;
  static constexpr uint32_t kCsMask = 1UL << 25;
  static constexpr uint32_t kMosiMask = 1UL << 20;
  static constexpr uint32_t kMisoMask = 1UL << 24;
  static constexpr uint32_t kWpMask = 1UL << 22;
  static constexpr uint32_t kHoldMask = 1UL << 23;

  uint32_t jedecId_ = 0;
  bool ready_ = false;

  static void select() { NRF_P0->OUTCLR = kCsMask; }
  static void deselect() {
    NRF_P0->OUTSET = kCsMask;
    NRF_P0->OUTCLR = kSckMask;
  }

  static uint8_t transfer(uint8_t outgoing) {
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
      incoming = static_cast<uint8_t>(
          (incoming << 1) | ((NRF_P0->IN & kMisoMask) ? 1 : 0));
    }
    NRF_P0->OUTCLR = kSckMask;
    return incoming;
  }

  static void sendAddress(uint32_t address) {
    transfer(static_cast<uint8_t>(address >> 16));
    transfer(static_cast<uint8_t>(address >> 8));
    transfer(static_cast<uint8_t>(address));
  }

  static void sendSimpleCommand(uint8_t command) {
    select();
    transfer(command);
    deselect();
    delayMicroseconds(30);
  }

  uint8_t readStatus() {
    select();
    transfer(0x05);
    const uint8_t status = transfer(0x00);
    deselect();
    return status;
  }

  bool writeEnable() {
    sendSimpleCommand(0x06);
    return (readStatus() & 0x02) != 0;
  }

  bool pageProgram(uint32_t address, const uint8_t* buffer, uint32_t length) {
    if (length == 0 || length > 256 ||
        ((address & 0xFF) + length) > 256 || !waitUntilReady() ||
        !writeEnable()) {
      return false;
    }

    select();
    transfer(0x02);
    sendAddress(address);
    for (uint32_t index = 0; index < length; ++index) {
      transfer(buffer[index]);
    }
    deselect();
    return waitUntilReady(100);
  }
};

RawSpiFlash flash;
BLEUart bleUart(512);

constexpr char kBleDeviceName[] = "LLM Dict Recorder";
constexpr uint8_t kBleProductSignature[] = {'L', 'L', 'M', 'D', '1'};
constexpr uint8_t kBleProtocolVersion = 1;
constexpr size_t kBleCommandBufferSize = 32;
constexpr size_t kBleFrameSize = 12;

enum class BleTransferPhase : uint8_t {
  kIdle,
  kHeader,
  kData,
  kEnd,
};

enum class RecorderState : uint8_t {
  kIdle,
  kErasing,
  kRecording,
  kFinalizing,
  kSending,
  kFault,
};

alignas(4) int16_t pdmBuffer[kPdmBufferBytes / sizeof(int16_t)];
alignas(4) uint8_t audioRing[kRingSize];
alignas(4) uint8_t transferBuffer[512];

volatile uint32_t ringHead = 0;
volatile uint32_t ringTail = 0;
volatile uint32_t droppedAudioBytes = 0;
volatile bool captureAudio = false;

RecorderState recorderState = RecorderState::kIdle;
bool flashReady = false;
bool microphoneRunning = false;
bool storedRecordingValid = false;
bool storageWriteFailed = false;
bool autoStopRequested = false;
bool lastRawButtonState = HIGH;
bool stableButtonState = HIGH;
uint32_t lastRawButtonChangeMs = 0;
uint32_t lastStatusMs = 0;
uint32_t audioBytesWritten = 0;
uint32_t storedWavSize = 0;
uint8_t bleCommandBuffer[kBleCommandBufferSize];
size_t bleCommandLength = 0;
BleTransferPhase bleTransferPhase = BleTransferPhase::kIdle;
uint32_t bleTransferOffset = 0;
uint32_t bleTransferCrc = 0xFFFFFFFFUL;
uint16_t blePendingChunkLength = 0;
bool bleInfoPending = false;
bool bleDisconnected = false;

void setLed(bool on) {
  digitalWrite(LED_BUILTIN, on ? LED_STATE_ON : !LED_STATE_ON);
}

void writeLe16(uint8_t* destination, uint16_t value) {
  destination[0] = static_cast<uint8_t>(value);
  destination[1] = static_cast<uint8_t>(value >> 8);
}

void writeLe32(uint8_t* destination, uint32_t value) {
  destination[0] = static_cast<uint8_t>(value);
  destination[1] = static_cast<uint8_t>(value >> 8);
  destination[2] = static_cast<uint8_t>(value >> 16);
  destination[3] = static_cast<uint8_t>(value >> 24);
}

uint32_t readLe32(const uint8_t* source) {
  return static_cast<uint32_t>(source[0]) |
         (static_cast<uint32_t>(source[1]) << 8) |
         (static_cast<uint32_t>(source[2]) << 16) |
         (static_cast<uint32_t>(source[3]) << 24);
}

void buildWavHeader(uint8_t* header, uint32_t audioBytes, bool finalized) {
  memset(header, 0, kWavHeaderSize);
  memcpy(header + 0, "RIFF", 4);
  writeLe32(header + 4, finalized ? 36 + audioBytes : 0xFFFFFFFFUL);
  memcpy(header + 8, "WAVE", 4);
  memcpy(header + 12, "fmt ", 4);
  writeLe32(header + 16, 16);
  writeLe16(header + 20, 1);
  writeLe16(header + 22, kChannels);
  writeLe32(header + 24, kSampleRate);
  writeLe32(header + 28, kBytesPerSecond);
  writeLe16(header + 32, kChannels * (kBitsPerSample / 8));
  writeLe16(header + 34, kBitsPerSample);
  memcpy(header + 36, "data", 4);
  writeLe32(header + 40, finalized ? audioBytes : 0xFFFFFFFFUL);
}

bool inspectStoredRecording() {
  uint8_t header[kWavHeaderSize];
  if (flash.readBuffer(0, header, sizeof(header)) != sizeof(header)) {
    return false;
  }

  if (memcmp(header + 0, "RIFF", 4) != 0 ||
      memcmp(header + 8, "WAVE", 4) != 0 ||
      memcmp(header + 12, "fmt ", 4) != 0 ||
      memcmp(header + 36, "data", 4) != 0) {
    return false;
  }

  const uint32_t riffSize = readLe32(header + 4);
  const uint32_t dataSize = readLe32(header + 40);
  if (dataSize == 0 || dataSize > kPrototypeAudioLimit ||
      dataSize > flash.size() - kWavHeaderSize || riffSize != 36 + dataSize) {
    return false;
  }

  storedWavSize = kWavHeaderSize + dataSize;
  return true;
}

bool startMicrophone() {
  if (microphoneRunning) {
    return true;
  }

  PDM.onReceive([]() {
    const int available = PDM.available();
    if (available <= 0) {
      return;
    }

    const int requested =
        min(available, static_cast<int>(sizeof(pdmBuffer)));
    const int bytesRead = PDM.read(pdmBuffer, requested);
    if (!captureAudio || bytesRead <= 0) {
      return;
    }

    const uint32_t head = ringHead;
    const uint32_t tail = ringTail;
    const uint32_t freeBytes =
        (tail - head - 1U) & static_cast<uint32_t>(kRingMask);
    if (static_cast<uint32_t>(bytesRead) > freeBytes) {
      droppedAudioBytes += static_cast<uint32_t>(bytesRead);
      return;
    }

    const uint8_t* source = reinterpret_cast<const uint8_t*>(pdmBuffer);
    for (int index = 0; index < bytesRead; ++index) {
      audioRing[(head + static_cast<uint32_t>(index)) & kRingMask] =
          source[index];
    }
    ringHead = (head + static_cast<uint32_t>(bytesRead)) & kRingMask;
  });
  PDM.setBufferSize(sizeof(pdmBuffer));
  microphoneRunning = PDM.begin(kChannels, kSampleRate);
  if (microphoneRunning) {
    PDM.setGain(kPdmGain);
  }
  return microphoneRunning;
}

void stopMicrophone() {
  if (microphoneRunning) {
    PDM.end();
    microphoneRunning = false;
  }
}

void resetAudioRing() {
  noInterrupts();
  ringHead = 0;
  ringTail = 0;
  droppedAudioBytes = 0;
  interrupts();
}

uint32_t ringBytesAvailable() {
  const uint32_t head = ringHead;
  const uint32_t tail = ringTail;
  return (head - tail) & static_cast<uint32_t>(kRingMask);
}

bool drainAudioRing() {
  while (ringBytesAvailable() > 0) {
    const uint32_t tail = ringTail;
    const uint32_t available = ringBytesAvailable();
    const uint32_t contiguous = min(
        available, static_cast<uint32_t>(kRingSize - static_cast<size_t>(tail)));
    const uint32_t capacityLeft = kPrototypeAudioLimit - audioBytesWritten;
    uint32_t bytesToWrite = min(contiguous, capacityLeft);
    bytesToWrite = min(bytesToWrite,
                       static_cast<uint32_t>(sizeof(transferBuffer)));

    if (bytesToWrite == 0) {
      autoStopRequested = true;
      return true;
    }

    const uint32_t address = kWavHeaderSize + audioBytesWritten;
    const uint32_t written =
        flash.writeBuffer(address, audioRing + tail, bytesToWrite);
    if (written != bytesToWrite) {
      storageWriteFailed = true;
      return false;
    }

    ringTail = (tail + written) & static_cast<uint32_t>(kRingMask);
    audioBytesWritten += written;
    if (audioBytesWritten >= kPrototypeAudioLimit) {
      autoStopRequested = true;
      return true;
    }
  }
  return true;
}

bool eraseStorage() {
  Serial.println("RECORDING:PREPARING,ERASING_FLASH");
  recorderState = RecorderState::kErasing;
  if (!flash.eraseChip()) {
    Serial.println("ERROR:FLASH_ERASE_COMMAND_FAILED");
    return false;
  }

  const uint32_t startedMs = millis();
  uint32_t lastBlinkMs = startedMs;
  bool ledOn = true;
  setLed(ledOn);
  while (!flash.isReady()) {
    const uint32_t nowMs = millis();
    if (nowMs - lastBlinkMs >= 100) {
      lastBlinkMs = nowMs;
      ledOn = !ledOn;
      setLed(ledOn);
    }
    if (nowMs - startedMs >= kEraseTimeoutMs) {
      Serial.println("ERROR:FLASH_ERASE_TIMEOUT");
      setLed(false);
      return false;
    }
    delay(1);
  }

  uint8_t erasedProbe[32];
  if (flash.readBuffer(0, erasedProbe, sizeof(erasedProbe)) !=
      sizeof(erasedProbe)) {
    Serial.println("ERROR:FLASH_ERASE_VERIFY_READ_FAILED");
    setLed(false);
    return false;
  }
  for (uint8_t value : erasedProbe) {
    if (value != 0xFF) {
      Serial.println("ERROR:FLASH_ERASE_VERIFY_FAILED");
      setLed(false);
      return false;
    }
  }
  return true;
}

void beginRecording() {
  if (!flashReady || recorderState != RecorderState::kIdle) {
    Serial.println("ERROR:RECORDING_START_NOT_AVAILABLE");
    return;
  }

  if (!eraseStorage()) {
    recorderState = RecorderState::kFault;
    return;
  }

  uint8_t header[kWavHeaderSize];
  buildWavHeader(header, 0, false);
  if (flash.writeBuffer(0, header, sizeof(header)) != sizeof(header)) {
    Serial.println("ERROR:WAV_HEADER_WRITE_FAILED");
    recorderState = RecorderState::kFault;
    setLed(false);
    return;
  }

  resetAudioRing();
  audioBytesWritten = 0;
  storedWavSize = 0;
  storedRecordingValid = false;
  storageWriteFailed = false;
  autoStopRequested = false;

  noInterrupts();
  captureAudio = true;
  interrupts();
  recorderState = RecorderState::kRecording;
  setLed(true);
  Serial.println("RECORDING:STARTED");
  bleInfoPending = true;
}

void finishRecording(const char* reason) {
  if (recorderState != RecorderState::kRecording) {
    return;
  }

  noInterrupts();
  captureAudio = false;
  interrupts();
  recorderState = RecorderState::kFinalizing;

  if (!drainAudioRing() || storageWriteFailed) {
    Serial.println("ERROR:AUDIO_FLASH_WRITE_FAILED");
    recorderState = RecorderState::kFault;
    setLed(false);
    return;
  }

  if (audioBytesWritten == 0) {
    Serial.println("ERROR:EMPTY_RECORDING");
    recorderState = RecorderState::kIdle;
    setLed(false);
    return;
  }

  uint8_t header[kWavHeaderSize];
  buildWavHeader(header, audioBytesWritten, true);
  if (flash.writeBuffer(0, header, sizeof(header)) != sizeof(header)) {
    Serial.println("ERROR:WAV_FINALIZE_FAILED");
    recorderState = RecorderState::kFault;
    setLed(false);
    return;
  }
  flash.waitUntilReady();

  storedWavSize = kWavHeaderSize + audioBytesWritten;
  storedRecordingValid = inspectStoredRecording();
  recorderState = storedRecordingValid ? RecorderState::kIdle
                                       : RecorderState::kFault;
  setLed(false);

  Serial.print("RECORDING:STOPPED,REASON=");
  Serial.print(reason);
  Serial.print(",AUDIO_BYTES=");
  Serial.print(audioBytesWritten);
  Serial.print(",DURATION_MS=");
  const uint32_t durationMs = static_cast<uint32_t>(
      (static_cast<uint64_t>(audioBytesWritten) * 1000ULL) / kBytesPerSecond);
  Serial.print(durationMs);
  Serial.print(",DROPPED_BYTES=");
  Serial.println(droppedAudioBytes);
  Serial.println(storedRecordingValid ? "WAV:READY" : "ERROR:WAV_VERIFY_FAILED");
  bleInfoPending = true;
}

const char* stateName() {
  switch (recorderState) {
    case RecorderState::kIdle:
      return "IDLE";
    case RecorderState::kErasing:
      return "ERASING";
    case RecorderState::kRecording:
      return "RECORDING";
    case RecorderState::kFinalizing:
      return "FINALIZING";
    case RecorderState::kSending:
      return "SENDING";
    case RecorderState::kFault:
      return "FAULT";
  }
  return "UNKNOWN";
}

void printInfo() {
  Serial.print("INFO:STATE=");
  Serial.print(stateName());
  Serial.print(",FLASH_READY=");
  Serial.print(flashReady ? "YES" : "NO");
  Serial.print(",FLASH_BYTES=");
  Serial.print(flashReady ? flash.size() : 0);
  Serial.print(",WAV_READY=");
  Serial.print(storedRecordingValid ? "YES" : "NO");
  Serial.print(",WAV_BYTES=");
  Serial.print(storedRecordingValid ? storedWavSize : 0);
  Serial.print(",AUDIO_BYTES=");
  Serial.print(audioBytesWritten);
  Serial.print(",DROPPED_BYTES=");
  Serial.println(droppedAudioBytes);
}

uint32_t crc32Update(uint32_t crc, const uint8_t* data, uint32_t length) {
  for (uint32_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320UL : 0);
    }
  }
  return crc;
}

uint8_t bleStateCode() {
  switch (recorderState) {
    case RecorderState::kIdle:
      return 0;
    case RecorderState::kRecording:
      return 1;
    case RecorderState::kErasing:
    case RecorderState::kFinalizing:
    case RecorderState::kSending:
      return 2;
    case RecorderState::kFault:
      return 3;
  }
  return 3;
}

bool writeBleFrame(const uint8_t* frame, uint16_t length) {
  return Bluefruit.connected() && bleUart.notifyEnabled() &&
         bleUart.write(frame, length) == length;
}

bool sendBleInfo() {
  uint8_t frame[kBleFrameSize] = {'L', 'D', 'I', '1'};
  frame[4] = kBleProtocolVersion;
  frame[5] = bleStateCode();
  frame[6] = (storedRecordingValid ? 0x01 : 0x00) |
             (bleTransferPhase != BleTransferPhase::kIdle ? 0x02 : 0x00);
  frame[7] = kPdmGain;
  writeLe32(frame + 8, storedRecordingValid ? storedWavSize : 0);
  return writeBleFrame(frame, sizeof(frame));
}

void cancelBleTransfer(const char* reason) {
  if (bleTransferPhase == BleTransferPhase::kIdle) {
    return;
  }
  bleTransferPhase = BleTransferPhase::kIdle;
  blePendingChunkLength = 0;
  Serial.print("BLE_TRANSFER:CANCELLED,REASON=");
  Serial.println(reason);

  if (recorderState == RecorderState::kSending) {
    recorderState = RecorderState::kIdle;
    if (!startMicrophone()) {
      recorderState = RecorderState::kFault;
      Serial.println("ERROR:PDM_RESTART_FAILED");
    }
  }
  bleInfoPending = true;
}

bool primeBleCrc(uint32_t offset) {
  bleTransferCrc = 0xFFFFFFFFUL;
  uint32_t address = 0;
  while (address < offset) {
    const uint32_t chunk =
        min(static_cast<uint32_t>(sizeof(transferBuffer)), offset - address);
    if (flash.readBuffer(address, transferBuffer, chunk) != chunk) {
      return false;
    }
    bleTransferCrc = crc32Update(bleTransferCrc, transferBuffer, chunk);
    address += chunk;
    yield();
  }
  return true;
}

void startBleTransfer(uint32_t offset) {
  if (recorderState != RecorderState::kIdle || !storedRecordingValid ||
      offset > storedWavSize || !Bluefruit.connected() ||
      !bleUart.notifyEnabled()) {
    bleInfoPending = true;
    return;
  }

  stopMicrophone();
  recorderState = RecorderState::kSending;
  bleTransferOffset = offset;
  blePendingChunkLength = 0;
  if (!primeBleCrc(offset)) {
    recorderState = RecorderState::kFault;
    bleTransferPhase = BleTransferPhase::kIdle;
    Serial.println("ERROR:BLE_CRC_READ_FAILED");
    return;
  }
  bleTransferPhase = BleTransferPhase::kHeader;
  Serial.print("BLE_TRANSFER:START,OFFSET=");
  Serial.print(offset);
  Serial.print(",TOTAL=");
  Serial.println(storedWavSize);
}

void pumpBleTransfer() {
  if (bleTransferPhase == BleTransferPhase::kIdle) {
    return;
  }
  if (!Bluefruit.connected() || !bleUart.notifyEnabled()) {
    cancelBleTransfer("DISCONNECTED");
    return;
  }

  if (bleTransferPhase == BleTransferPhase::kHeader) {
    uint8_t frame[kBleFrameSize] = {'L', 'D', 'T', '1'};
    writeLe32(frame + 4, storedWavSize);
    writeLe32(frame + 8, bleTransferOffset);
    if (writeBleFrame(frame, sizeof(frame))) {
      bleTransferPhase = BleTransferPhase::kData;
    }
    return;
  }

  if (bleTransferPhase == BleTransferPhase::kData) {
    if (bleTransferOffset >= storedWavSize) {
      bleTransferPhase = BleTransferPhase::kEnd;
      return;
    }

    if (blePendingChunkLength == 0) {
      BLEConnection* connection = Bluefruit.Connection(Bluefruit.connHandle());
      const uint16_t mtuPayload =
          connection && connection->getMtu() > 3 ? connection->getMtu() - 3
                                                 : 20;
      const uint32_t chunk = min(
          min(static_cast<uint32_t>(sizeof(transferBuffer)),
              static_cast<uint32_t>(mtuPayload)),
          storedWavSize - bleTransferOffset);
      if (flash.readBuffer(bleTransferOffset, transferBuffer, chunk) != chunk) {
        recorderState = RecorderState::kFault;
        bleTransferPhase = BleTransferPhase::kIdle;
        Serial.println("ERROR:BLE_WAV_READ_FAILED");
        return;
      }
      blePendingChunkLength = static_cast<uint16_t>(chunk);
    }

    if (bleUart.write(transferBuffer, blePendingChunkLength) ==
        blePendingChunkLength) {
      bleTransferCrc =
          crc32Update(bleTransferCrc, transferBuffer, blePendingChunkLength);
      bleTransferOffset += blePendingChunkLength;
      blePendingChunkLength = 0;
    }
    return;
  }

  uint8_t frame[kBleFrameSize] = {'L', 'D', 'E', '1'};
  writeLe32(frame + 4, storedWavSize);
  writeLe32(frame + 8, bleTransferCrc ^ 0xFFFFFFFFUL);
  if (!writeBleFrame(frame, sizeof(frame))) {
    return;
  }

  Serial.print("BLE_TRANSFER:COMPLETE,BYTES=");
  Serial.println(storedWavSize);
  bleTransferPhase = BleTransferPhase::kIdle;
  recorderState = RecorderState::kIdle;
  blePendingChunkLength = 0;
  if (!startMicrophone()) {
    recorderState = RecorderState::kFault;
    Serial.println("ERROR:PDM_RESTART_FAILED");
  }
  bleInfoPending = true;
}

void consumeBleCommand(size_t length) {
  if (length >= bleCommandLength) {
    bleCommandLength = 0;
    return;
  }
  memmove(bleCommandBuffer, bleCommandBuffer + length,
          bleCommandLength - length);
  bleCommandLength -= length;
}

void parseBleCommands() {
  while (bleCommandLength >= 4) {
    if (memcmp(bleCommandBuffer, "LDI1", 4) == 0) {
      bleInfoPending = true;
      consumeBleCommand(4);
    } else if (memcmp(bleCommandBuffer, "LDC1", 4) == 0) {
      cancelBleTransfer("CLIENT");
      consumeBleCommand(4);
    } else if (memcmp(bleCommandBuffer, "LDG1", 4) == 0) {
      if (bleCommandLength < 8) {
        return;
      }
      const uint32_t offset = readLe32(bleCommandBuffer + 4);
      consumeBleCommand(8);
      startBleTransfer(offset);
    } else {
      consumeBleCommand(1);
    }
  }
}

void handleBleCommands() {
  while (bleUart.available() > 0) {
    if (bleCommandLength == sizeof(bleCommandBuffer)) {
      consumeBleCommand(1);
    }
    const int value = bleUart.read();
    if (value >= 0) {
      bleCommandBuffer[bleCommandLength++] = static_cast<uint8_t>(value);
    }
  }
  parseBleCommands();
}

void onBleConnected(uint16_t connectionHandle) {
  BLEConnection* connection = Bluefruit.Connection(connectionHandle);
  if (connection) {
    connection->requestPHY();
    connection->requestDataLengthUpdate();
    connection->requestMtuExchange(247);
  }
  Serial.println("BLE:CONNECTED");
  bleInfoPending = true;
}

void onBleDisconnected(uint16_t connectionHandle, uint8_t reason) {
  (void)connectionHandle;
  (void)reason;
  bleDisconnected = true;
  Serial.println("BLE:DISCONNECTED");
}

void onBleNotifyChanged(uint16_t connectionHandle, bool enabled) {
  (void)connectionHandle;
  if (enabled) {
    bleInfoPending = true;
  }
}

void setupBle() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.autoConnLed(false);
  Bluefruit.setTxPower(4);
  Bluefruit.setName(kBleDeviceName);
  Bluefruit.Periph.setConnectCallback(onBleConnected);
  Bluefruit.Periph.setDisconnectCallback(onBleDisconnected);
  Bluefruit.Periph.setConnInterval(6, 12);

  bleUart.begin();
  bleUart.setNotifyCallback(onBleNotifyChanged);

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(bleUart);
  Bluefruit.Advertising.addManufacturerData(kBleProductSignature,
                                             sizeof(kBleProductSignature));
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
  Serial.println("BLE:ADVERTISING,NAME=LLM Dict Recorder,PROTOCOL=1");
}

void sendStoredWav() {
  if (recorderState != RecorderState::kIdle || !storedRecordingValid) {
    Serial.println("ERROR:NO_FINALIZED_WAV");
    return;
  }

  recorderState = RecorderState::kSending;
  stopMicrophone();
  Serial.print("WAV_BEGIN ");
  Serial.println(storedWavSize);
  Serial.flush();

  uint32_t address = 0;
  while (address < storedWavSize) {
    const uint32_t chunk =
        min(static_cast<uint32_t>(sizeof(transferBuffer)),
            storedWavSize - address);
    if (flash.readBuffer(address, transferBuffer, chunk) != chunk) {
      Serial.println("\nWAV_ERROR READ_FAILED");
      recorderState = RecorderState::kFault;
      setLed(false);
      return;
    }

    uint32_t sent = 0;
    while (sent < chunk) {
      sent += Serial.write(transferBuffer + sent, chunk - sent);
      yield();
    }
    address += chunk;
  }
  Serial.flush();
  Serial.println();
  Serial.println("WAV_END");

  recorderState = RecorderState::kIdle;
  if (!startMicrophone()) {
    Serial.println("ERROR:PDM_RESTART_FAILED");
    recorderState = RecorderState::kFault;
  }
}

void handleSerialCommands() {
  while (Serial.available() > 0) {
    const char command = static_cast<char>(Serial.read());
    if (command == 'I' || command == 'i') {
      printInfo();
    } else if (command == 'G' || command == 'g') {
      sendStoredWav();
    } else if (command != '\r' && command != '\n' && command != ' ') {
      Serial.println("ERROR:UNKNOWN_COMMAND,USE_I_OR_G");
    }
  }
}

void handleButtonPress() {
  if (recorderState == RecorderState::kIdle) {
    beginRecording();
  } else if (recorderState == RecorderState::kRecording) {
    finishRecording("BUTTON");
  } else {
    Serial.print("BUTTON:IGNORED,STATE=");
    Serial.println(stateName());
  }
}

void updateButton(uint32_t nowMs) {
  const bool rawState = digitalRead(kButtonPin);
  if (rawState != lastRawButtonState) {
    lastRawButtonState = rawState;
    lastRawButtonChangeMs = nowMs;
  }

  if (rawState != stableButtonState &&
      nowMs - lastRawButtonChangeMs >= kDebounceMs) {
    stableButtonState = rawState;
    Serial.println(stableButtonState == LOW ? "BUTTON:PRESSED"
                                            : "BUTTON:RELEASED");
    if (stableButtonState == LOW) {
      handleButtonPress();
    }
  }
}

void reportRecordingStatus(uint32_t nowMs) {
  if (recorderState != RecorderState::kRecording ||
      nowMs - lastStatusMs < kStatusIntervalMs) {
    return;
  }
  lastStatusMs = nowMs;
  Serial.print("RECORDING:ACTIVE,AUDIO_BYTES=");
  Serial.print(audioBytesWritten);
  Serial.print(",BUFFERED_BYTES=");
  Serial.print(ringBytesAvailable());
  Serial.print(",DROPPED_BYTES=");
  Serial.println(droppedAudioBytes);
}

}  // namespace

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  setLed(false);
  pinMode(kButtonPin, INPUT_PULLUP);
  lastRawButtonState = digitalRead(kButtonPin);
  stableButtonState = lastRawButtonState;
  lastRawButtonChangeMs = millis();

  Serial.begin(kSerialBaud);
  const uint32_t serialWaitStartedMs = millis();
  while (!Serial && millis() - serialWaitStartedMs < kSerialWaitMs) {
    delay(10);
  }

  Serial.println();
  Serial.println("BOOT:LLM_DICT_RECORDER_V1");
  Serial.println("BOARD:XIAO_NRF52840_SENSE_PLUS");
  Serial.println("BUTTON:D10_TO_GND,ACTIVE_LOW,INPUT_PULLUP");
  Serial.println("AUDIO:PDM,MONO,16000_HZ,16_BIT");
  Serial.print("AUDIO:PDM_GAIN=");
  Serial.println(kPdmGain);
  Serial.println("SERIAL_COMMANDS:I=INFO,G=GET_WAV");

  flashReady = flash.begin();
  if (flashReady) {
    flashReady = flash.getJEDECID() == kExpectedJedecId &&
                 flash.size() == kExpectedFlashSize;
  }
  Serial.print("FLASH:JEDEC=0x");
  Serial.print(flashReady ? flash.getJEDECID() : 0, HEX);
  Serial.print(",BYTES=");
  Serial.println(flashReady ? flash.size() : 0);
  if (!flashReady) {
    Serial.println("FATAL:UNEXPECTED_FLASH,ERASE_DISABLED");
    recorderState = RecorderState::kFault;
  } else {
    storedRecordingValid = inspectStoredRecording();
    if (storedRecordingValid) {
      audioBytesWritten = storedWavSize - kWavHeaderSize;
      Serial.print("WAV:FOUND,BYTES=");
      Serial.println(storedWavSize);
    } else {
      Serial.println("WAV:NONE");
    }
  }

  setupBle();

  if (!startMicrophone()) {
    Serial.println("FATAL:PDM_START_FAILED");
    recorderState = RecorderState::kFault;
  }

  Serial.print("BUTTON:INITIAL=");
  Serial.println(stableButtonState == LOW ? "PRESSED" : "RELEASED");
  Serial.println(recorderState == RecorderState::kFault ? "READY:FAULT"
                                                        : "READY");
  printInfo();
}

void loop() {
  const uint32_t nowMs = millis();
  updateButton(nowMs);
  handleSerialCommands();
  handleBleCommands();

  if (bleDisconnected) {
    bleDisconnected = false;
    cancelBleTransfer("DISCONNECTED");
  }

  if (recorderState == RecorderState::kRecording) {
    if (!drainAudioRing()) {
      noInterrupts();
      captureAudio = false;
      interrupts();
      recorderState = RecorderState::kFault;
      setLed(false);
      Serial.println("ERROR:AUDIO_FLASH_WRITE_FAILED");
    } else if (autoStopRequested) {
      finishRecording("CAPACITY");
    }
  }

  pumpBleTransfer();
  if (bleInfoPending && bleTransferPhase == BleTransferPhase::kIdle &&
      sendBleInfo()) {
    bleInfoPending = false;
  }

  reportRecordingStatus(nowMs);
  delay(1);
}
