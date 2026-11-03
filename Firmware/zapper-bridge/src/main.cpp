// Zapper Bluetooth bridge.
//
// The Mac cannot present itself to a TV as a Bluetooth keyboard or mouse —
// macOS refuses the HID-over-GATT service to apps. This board does it
// instead: the TV pairs with it once as "Zapper Remote", and Zapper drives it
// over USB serial with one-line commands.
//
// Protocol (115200 baud, one command per line, hex numbers without 0x):
//   PING                 -> PONG <1 if a TV is connected, else 0>
//   K <usage> [mods]     tap a keyboard key (HID usage page 0x07)
//   KD <usage> / KU <usage>   hold / release a keyboard key
//   C <usage>            tap a consumer key (page 0x0C: volume, home, back…)
//   CD <usage> / CU      hold / release a consumer key
//   T <text>             type ASCII text (US layout)
//   M <dx> <dy> [wheel]  move the mouse (decimal, any size; sent in steps)
//   B <mask>             set mouse buttons (1 left, 2 right, 4 middle)
//   R                    release everything
// Every command answers OK or ERR <why>. The board also reports
// "STATE 1" / "STATE 0" by itself when a TV connects or disconnects.

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>

static const char *kName = "Zapper Remote";

enum : uint8_t { kKeyboardId = 1, kMouseId = 2, kConsumerId = 3 };

static const uint8_t kReportMap[] = {
    // Keyboard: modifiers, reserved byte, six keys.
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, kKeyboardId,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, 0xFF, 0x00,
    0x05, 0x07, 0x19, 0x00, 0x2A, 0xFF, 0x00, 0x81, 0x00,
    0xC0,
    // Mouse: three buttons, relative X, Y and wheel.
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, kMouseId,
    0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
    0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
    0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
    0xC0, 0xC0,
    // Consumer control: one 16-bit usage (volume, media, AC Home/Back…).
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, kConsumerId,
    0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03,
    0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
    0xC0,
};

static NimBLEServer *server;
static NimBLEHIDDevice *hid;
static NimBLECharacteristic *keyboardIn, *mouseIn, *consumerIn;
static volatile bool connected = false;
static bool reportedConnected = false;

static uint8_t modifiers = 0;
static uint8_t keys[6] = {0};
static uint8_t buttons = 0;
static uint16_t consumerHeld = 0;
// Mouse motion is accumulated and flushed at most every 10 ms: the Mac sends
// drag events faster than a BLE connection interval.
static long pendingX = 0, pendingY = 0, pendingWheel = 0;
static uint32_t lastMouseFlush = 0;

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer *, ble_gap_conn_desc *desc) override {
        connected = true;
        // Ask for a short connection interval so the pointer feels live.
        server->updateConnParams(desc->conn_handle, 6, 12, 0, 400);
    }
    void onDisconnect(NimBLEServer *) override {
        connected = false;
        NimBLEDevice::startAdvertising();
    }
};

static void sendKeyboard() {
    if (!connected) return;
    uint8_t report[8] = {modifiers, 0, keys[0], keys[1], keys[2], keys[3], keys[4], keys[5]};
    keyboardIn->setValue(report, sizeof(report));
    keyboardIn->notify();
}

static void sendConsumer() {
    if (!connected) return;
    uint8_t report[2] = {uint8_t(consumerHeld & 0xFF), uint8_t(consumerHeld >> 8)};
    consumerIn->setValue(report, sizeof(report));
    consumerIn->notify();
}

static void sendMouse(int8_t dx, int8_t dy, int8_t wheel) {
    if (!connected) return;
    uint8_t report[4] = {buttons, uint8_t(dx), uint8_t(dy), uint8_t(wheel)};
    mouseIn->setValue(report, sizeof(report));
    mouseIn->notify();
}

static void keyDown(uint8_t usage) {
    for (uint8_t k : keys) if (k == usage) return;
    for (uint8_t &k : keys) if (k == 0) { k = usage; break; }
    sendKeyboard();
}

static void keyUp(uint8_t usage) {
    for (uint8_t &k : keys) if (k == usage) k = 0;
    sendKeyboard();
}

static void tapKey(uint8_t usage, uint8_t mods) {
    uint8_t saved = modifiers;
    modifiers |= mods;
    keyDown(usage);
    delay(12);
    keyUp(usage);
    modifiers = saved;
    sendKeyboard();
    delay(12);
}

static void tapConsumer(uint16_t usage) {
    consumerHeld = usage;
    sendConsumer();
    delay(15);
    consumerHeld = 0;
    sendConsumer();
    delay(15);
}

/// US-layout HID usage for an ASCII character; shift is set when needed.
static bool asciiToUsage(char c, uint8_t &usage, bool &shift) {
    shift = false;
    if (c >= 'a' && c <= 'z') { usage = 0x04 + (c - 'a'); return true; }
    if (c >= 'A' && c <= 'Z') { usage = 0x04 + (c - 'A'); shift = true; return true; }
    if (c >= '1' && c <= '9') { usage = 0x1E + (c - '1'); return true; }
    if (c == '0') { usage = 0x27; return true; }
    static const char *plain   = " -=[]\\;'`,./\n\t";
    static const uint8_t plainU[] = {0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x28, 0x2B};
    static const char *shifted = "!@#$%^&*()_+{}|:\"~<>?";
    static const uint8_t shiftedU[] = {0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
                                       0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38};
    if (const char *p = strchr(plain, c)) { usage = plainU[p - plain]; return true; }
    if (const char *p = strchr(shifted, c)) { usage = shiftedU[p - shifted]; shift = true; return true; }
    return false;
}

static void typeText(const char *text) {
    for (const char *c = text; *c; ++c) {
        uint8_t usage; bool shift;
        if (asciiToUsage(*c, usage, shift)) tapKey(usage, shift ? 0x02 : 0);
    }
}

static void releaseAll() {
    modifiers = 0;
    memset(keys, 0, sizeof(keys));
    sendKeyboard();
    consumerHeld = 0;
    sendConsumer();
    buttons = 0;
    sendMouse(0, 0, 0);
    pendingX = pendingY = pendingWheel = 0;
}

static void flushMouse() {
    while (pendingX || pendingY || pendingWheel) {
        int8_t dx = constrain(pendingX, -127, 127);
        int8_t dy = constrain(pendingY, -127, 127);
        int8_t dw = constrain(pendingWheel, -127, 127);
        sendMouse(dx, dy, dw);
        pendingX -= dx; pendingY -= dy; pendingWheel -= dw;
        if (pendingX || pendingY || pendingWheel) delay(8);
    }
}

// MARK: - Serial

static void handle(Stream &port, char *line) {
    // The text is everything after "T ", spaces included, so it is taken
    // before strtok cuts the line up.
    if (line[0] == 'T' && (line[1] == ' ' || line[1] == 0)) {
        if (!connected) { port.print("ERR no-tv\n"); return; }
        typeText(line[1] ? line + 2 : "");
        port.print("OK\n");
        return;
    }
    char *cmd = strtok(line, " ");
    if (!cmd) return;
    char *a = strtok(nullptr, " ");
    char *b = strtok(nullptr, " ");
    char *c = strtok(nullptr, " ");
    auto hex = [](const char *s) { return s ? strtoul(s, nullptr, 16) : 0UL; };

    if (!strcmp(cmd, "PING")) { port.printf("PONG %d\n", connected ? 1 : 0); return; }
    if (!strcmp(cmd, "M") && a && b) {
        // No reply: moves stream in at drag rate and the Mac does not wait.
        if (!connected) return;
        pendingX += atol(a); pendingY += atol(b);
        if (c) pendingWheel += atol(c);
        return;
    }
    if (!connected && strcmp(cmd, "R")) { port.print("ERR no-tv\n"); return; }

    if (!strcmp(cmd, "K") && a)       tapKey(hex(a), hex(b));
    else if (!strcmp(cmd, "KD") && a) keyDown(hex(a));
    else if (!strcmp(cmd, "KU") && a) keyUp(hex(a));
    else if (!strcmp(cmd, "C") && a)  tapConsumer(hex(a));
    else if (!strcmp(cmd, "CD") && a) { consumerHeld = hex(a); sendConsumer(); }
    else if (!strcmp(cmd, "CU"))      { consumerHeld = 0; sendConsumer(); }
    else if (!strcmp(cmd, "B") && a)  { flushMouse(); buttons = hex(a) & 0x07; sendMouse(0, 0, 0); }
    else if (!strcmp(cmd, "R"))       releaseAll();
    else { port.print("ERR unknown\n"); return; }
    port.print("OK\n");
}

struct LineReader {
    Stream *port;
    char buffer[256];
    size_t length;

    LineReader(Stream *port) : port(port), length(0) {}

    void poll() {
        while (port->available()) {
            char ch = port->read();
            if (ch == '\r') continue;
            if (ch == '\n') {
                buffer[length] = 0;
                if (length) handle(*port, buffer);
                length = 0;
            } else if (length < sizeof(buffer) - 1) {
                buffer[length++] = ch;
            }
        }
    }
};

// Boards with native USB (S3, C3) may be plugged in by either their USB port
// or their UART port; listen on both.
#if ARDUINO_USB_CDC_ON_BOOT
static LineReader readers[] = {LineReader(&Serial), LineReader(&Serial0)};
#else
static LineReader readers[] = {LineReader(&Serial)};
#endif

void setup() {
    Serial.begin(115200);
#if ARDUINO_USB_CDC_ON_BOOT
    Serial0.begin(115200);
#endif

    NimBLEDevice::init(kName);
    // Bond so the TV reconnects by itself after either side restarts. No
    // display or buttons here, so pairing is "just works".
    NimBLEDevice::setSecurityAuth(true, false, true);
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);

    server = NimBLEDevice::createServer();
    server->setCallbacks(new ServerCallbacks());

    hid = new NimBLEHIDDevice(server);
    keyboardIn = hid->inputReport(kKeyboardId);
    mouseIn = hid->inputReport(kMouseId);
    consumerIn = hid->inputReport(kConsumerId);
    hid->manufacturer()->setValue("Zapper");
    hid->pnp(0x02, 0x303A, 0x4001, 0x0100);   // Espressif USB vendor ID
    hid->hidInfo(0x00, 0x02);
    hid->reportMap((uint8_t *)kReportMap, sizeof(kReportMap));
    hid->startServices();
    hid->setBatteryLevel(100);

    NimBLEAdvertising *advertising = server->getAdvertising();
    advertising->setAppearance(0x03C1);   // keyboard
    advertising->addServiceUUID(hid->hidService()->getUUID());
    advertising->setScanResponse(true);
    advertising->start();

    for (auto &r : readers) r.port->print("ZAPPER-BRIDGE 1\n");
}

void loop() {
    for (auto &r : readers) r.poll();

    if (millis() - lastMouseFlush >= 10) {
        lastMouseFlush = millis();
        flushMouse();
    }
    if (connected != reportedConnected) {
        reportedConnected = connected;
        for (auto &r : readers) r.port->printf("STATE %d\n", reportedConnected ? 1 : 0);
    }
    delay(1);
}
