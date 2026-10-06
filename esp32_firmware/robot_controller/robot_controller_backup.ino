/*
 * Ramp bot + 4-servo arm - ESP32 + L298N + 4 DC motors + 4 servos
 * Bluetooth control (classic SPP) - made for the "Bluetooth Electronics"
 * Android app, but plain RC-car apps also work for driving.
 *
 * Pair the phone with "RampBot" in Android Bluetooth settings, then connect
 * from the app.
 *
 * ---------------- PROTOCOL ----------------
 * Drive (single characters, no terminator needed):
 *   F forward   B backward   L spin left   R spin right
 *   G fwd-left  I fwd-right  H back-left   J back-right
 *   S stop      0..9 speed   q full speed
 *
 * Arm / joystick (text lines ending in newline, '\r' or '#'):
 *   a<0-180>   servo 1 (base)       e.g.  a90
 *   b<0-180>   servo 2 (shoulder)
 *   c<0-180>   servo 3 (elbow)
 *   d<0-180>   servo 4 (gripper)
 *   j<x>,<y>   joystick, each -100..100 (x = turn, y = throttle)   e.g.  j-40,100
 *   P          arm back to home pose (single char)
 *
 * Servo power: use a separate 5-6V supply (BEC/buck) for the servos and
 * join its GND with the ESP32 and L298N grounds. Do NOT power them from the ESP32.
 */

#include "BluetoothSerial.h"

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled! Use an ESP32 Dev Module board.
#endif

BluetoothSerial SerialBT;

// ---------- Drive pins ----------
const int ENA = 14, IN1 = 26, IN2 = 27;   // Left motors
const int ENB = 32, IN3 = 25, IN4 = 33;   // Right motors

// ---------- Servo pins ----------
const int NUM_SERVOS = 4;
//                                 a   b   c   d
// NOTE: GPIO 34/35 are input-only on ESP32 and cannot drive servos.
// GPIO 12 is a boot-strapping pin: if the board fails to boot with a servo
// connected, unplug the servo signal wire while uploading/resetting, or move this to 18.
const int SERVO_PIN[NUM_SERVOS] = {12, 13, 18, 19};

// Per-servo safe limits (degrees) - narrow these to protect your arm/gripper
const int SERVO_MIN[NUM_SERVOS]  = {0,   0,   0,   0};
const int SERVO_MAX[NUM_SERVOS]  = {180, 180, 180, 180};
const int SERVO_HOME[NUM_SERVOS] = {90,  90,  90,  90};

const int SERVO_MIN_US = 500;             // pulse width at 0 deg   (use 1000 if servo buzzes at the ends)
const int SERVO_MAX_US = 2500;            // pulse width at 180 deg (use 2000 likewise)
const int SERVO_STEP_DEG = 2;             // degrees per update  -> smoothness vs speed
const unsigned long SERVO_UPDATE_MS = 15;

// ---------- Motor PWM ----------
const int PWM_FREQ = 2000;
const int PWM_RES  = 8;                   // 0..255

// ---------- Drive tuning ----------
const int  MIN_PWM       = 90;
const int  PIVOT_MIN_PWM = 210;
const int  KICK_PWM      = 255;
const unsigned long KICK_MS = 120;
const float TURN_GAIN    = 1.6;
const int  DIAG_TURN     = 60;
const int  JOY_DEADZONE  = 8;
const int  STEER_DIR     = -1;            // -1 = flipped steering; set to 1 to flip back

int maxPwm = 255;

bool leftMoving = false, rightMoving = false;
int lastSignL = 0, lastSignR = 0;
bool wasConnected = false;

int servoCur[NUM_SERVOS];
int servoTarget[NUM_SERVOS];
unsigned long lastServoUpdate = 0;

// Command timeout failsafe: stop motors if no command for 200ms
unsigned long lastCommandTime = 0;
const unsigned long COMMAND_TIMEOUT_MS = 200;

// Line parser state
String lineBuf = "";
bool lineMode = false;

// =====================================================================
//  PWM helpers
// =====================================================================
// Core 2.x channel map: 0,1 = motors, 2..5 = servos (motors and servos land on different timers, no clash)
void pwmSetup() {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(ENA, PWM_FREQ, PWM_RES);
  ledcAttach(ENB, PWM_FREQ, PWM_RES);
  for (int i = 0; i < NUM_SERVOS; i++) ledcAttach(SERVO_PIN[i], 50, 16);
#else
  ledcSetup(0, PWM_FREQ, PWM_RES);
  ledcSetup(1, PWM_FREQ, PWM_RES);
  ledcAttachPin(ENA, 0);
  ledcAttachPin(ENB, 1);
  for (int i = 0; i < NUM_SERVOS; i++) {
    ledcSetup(2 + i, 50, 16);
    ledcAttachPin(SERVO_PIN[i], 2 + i);
  }
#endif
}

void pwmWrite(bool left, int duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(left ? ENA : ENB, duty);
#else
  ledcWrite(left ? 0 : 1, duty);
#endif
}

void servoWrite(int i, int angle) {
  int us = map(angle, 0, 180, SERVO_MIN_US, SERVO_MAX_US);
  uint32_t duty = (uint32_t)us * 65535UL / 20000UL;   // 20 ms period, 16-bit
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(SERVO_PIN[i], duty);
#else
  ledcWrite(2 + i, duty);
#endif
}

// =====================================================================
//  Motors
// =====================================================================
void setSide(bool left, int v, int minPwm = MIN_PWM) {
  int a = left ? IN1 : IN3;
  int b = left ? IN2 : IN4;
  bool &moving = left ? leftMoving : rightMoving;
  int &lastSign = left ? lastSignL : lastSignR;

  if (v == 0) {
    digitalWrite(a, LOW); digitalWrite(b, LOW);
    pwmWrite(left, 0);
    moving = false;
    lastSign = 0;
    return;
  }

  int sign = v > 0 ? 1 : -1;
  digitalWrite(a, sign > 0 ? HIGH : LOW);
  digitalWrite(b, sign > 0 ? LOW : HIGH);

  int duty = map(abs(v), 1, 255, minPwm, 255);

  if (!moving || sign != lastSign) {      // kick on start and direction change
    pwmWrite(left, KICK_PWM);
    delay(KICK_MS);
    moving = true;
    lastSign = sign;
  }
  pwmWrite(left, duty);
}

void stopMotors() {
  setSide(true, 0);
  setSide(false, 0);
}

// x = turn (-100..100, + = right), y = throttle (-100..100)
void drive(int x, int y) {
  float xs = constrain(x * TURN_GAIN * STEER_DIR, -100, 100);

  if (y == 0 && xs != 0) {                // spin in place
    int v = (int)(fabs(xs) * 255 / 100.0);
    setSide(true,   xs > 0 ?  v : -v, PIVOT_MIN_PWM);
    setSide(false,  xs > 0 ? -v :  v, PIVOT_MIN_PWM);
    return;
  }

  float l = y + xs;
  float r = y - xs;
  float m = max(fabs(l), fabs(r));
  if (m > 100) { l = l * 100 / m; r = r * 100 / m; }

  int minL = (l * y < 0) ? PIVOT_MIN_PWM : MIN_PWM;
  int minR = (r * y < 0) ? PIVOT_MIN_PWM : MIN_PWM;

  setSide(true,  (int)(l * maxPwm / 100.0), minL);
  setSide(false, (int)(r * maxPwm / 100.0), minR);
}

// =====================================================================
//  Servos (smooth, non-blocking)
// =====================================================================
void setServoTarget(int i, int angle) {
  servoTarget[i] = constrain(angle, SERVO_MIN[i], SERVO_MAX[i]);
}

void armHome() {
  for (int i = 0; i < NUM_SERVOS; i++) setServoTarget(i, SERVO_HOME[i]);
}

void updateServos() {
  if (millis() - lastServoUpdate < SERVO_UPDATE_MS) return;
  lastServoUpdate = millis();
  for (int i = 0; i < NUM_SERVOS; i++) {
    if (servoCur[i] == servoTarget[i]) continue;
    int d = servoTarget[i] - servoCur[i];
    servoCur[i] += (abs(d) <= SERVO_STEP_DEG) ? d : (d > 0 ? SERVO_STEP_DEG : -SERVO_STEP_DEG);
    servoWrite(i, servoCur[i]);
  }
}

// =====================================================================
//  Command parsing
// =====================================================================
void handleCommand(char c) {              // single-character commands
  switch (c) {
    case 'F': drive(0, 100);               break;
    case 'B': drive(0, -100);              break;
    case 'L': drive(-100, 0);              break;
    case 'R': drive(100, 0);               break;
    case 'G': drive(-DIAG_TURN, 100);      break;
    case 'I': drive(DIAG_TURN, 100);       break;
    case 'H': drive(-DIAG_TURN, -100);     break;
    case 'J': drive(DIAG_TURN, -100);      break;
    case 'S': case 'D': stopMotors();      break;
    case 'P': armHome();                   break;
    case 'q': maxPwm = 255;                break;
    default:
      if (c >= '0' && c <= '9') maxPwm = 100 + (c - '0') * 17;   // 100..253
      break;
  }
}

void handleLine(const String &s) {        // "a90", "j-40,100"
  if (s.length() < 2) return;
  char t = s[0];

  if (t >= 'a' && t <= 'd') {
    setServoTarget(t - 'a', s.substring(1).toInt());
  } else if (t == 'j') {
    int comma = s.indexOf(',');
    if (comma < 0) return;
    int x = constrain(s.substring(1, comma).toInt(), -100, 100);
    int y = constrain(s.substring(comma + 1).toInt(), -100, 100);
    if (abs(x) < JOY_DEADZONE) x = 0;
    if (abs(y) < JOY_DEADZONE) y = 0;
    if (x == 0 && y == 0) stopMotors();
    else drive(x, y);
  }
}

void onChar(char c) {
  lastCommandTime = millis();          // reset failsafe timer on every byte
  if (lineMode) {
    if (c == '\n' || c == '\r' || c == '#') {
      handleLine(lineBuf);
      lineBuf = "";
      lineMode = false;
    } else if (lineBuf.length() < 24) {
      lineBuf += c;
    } else {                              // garbage - reset
      lineBuf = "";
      lineMode = false;
    }
    return;
  }

  if ((c >= 'a' && c <= 'd') || c == 'j') {   // start of a line command
    lineMode = true;
    lineBuf = String(c);
    return;
  }
  if (c == '\n' || c == '\r' || c == '#' || c == ' ') return;
  handleCommand(c);
}

// =====================================================================
//  Arduino
// =====================================================================
void setup() {
  Serial.begin(115200);
  pinMode(IN1, OUTPUT); pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT); pinMode(IN4, OUTPUT);
  pwmSetup();
  stopMotors();

  for (int i = 0; i < NUM_SERVOS; i++) {
    servoCur[i] = servoTarget[i] = SERVO_HOME[i];
    servoWrite(i, servoCur[i]);
  }

  SerialBT.begin("RampBot");
  Serial.println("Bluetooth started. Pair with 'RampBot'.");
}

void loop() {
  // Failsafe: stop the wheels if the phone disconnects
  bool connected = SerialBT.hasClient();
  if (wasConnected && !connected) {
    stopMotors();
    lineMode = false; lineBuf = "";
    Serial.println("Disconnected - wheels stopped");
  }
  wasConnected = connected;

  while (SerialBT.available()) onChar((char)SerialBT.read());
  while (Serial.available())   onChar((char)Serial.read());   // bench testing over USB

  // Failsafe: stop wheels if no command received within timeout
  if ((leftMoving || rightMoving) &&
      millis() - lastCommandTime > COMMAND_TIMEOUT_MS) {
    stopMotors();
    Serial.println("Command timeout - wheels stopped");
  }

  updateServos();
}
