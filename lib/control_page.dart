import 'dart:async';
import 'package:flutter/material.dart';
import 'bluetooth_service.dart' as bt;
import 'connection_page.dart';
import 'joystick_widget.dart';

enum ArmControlMode { jog, direct }

class ControlPage extends StatefulWidget {
  final bt.BluetoothService btService;

  const ControlPage({super.key, required this.btService});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  bt.BluetoothService get _bt => widget.btService;

  // Active D-pad button command for visual feedback
  String? _activeDpadButton;

  // Continuous drive: resend active command every 150ms so firmware timeout works
  Timer? _driveRepeatTimer;
  String? _activeDriveCmd;

  // Tracked servo angles: 0: Base (a), 1: Shoulder (b), 2: Elbow (c), 3: Gripper (d)
  final List<double> _servoAngles = [90.0, 90.0, 90.0, 90.0];
  final List<int> _lastSentAngles = [90, 90, 90, 90];

  // Arm control mode: jog (smooth continuous rate) vs direct (joystick position = angle)
  ArmControlMode _armMode = ArmControlMode.jog;

  // Jog speed: degrees per second
  static const double _jogSpeedDegPerSec = 120.0;  // 2.7x faster jog speed for quicker gripper response

  // Joystick deflections (-100..100)
  Offset _joy1Offset = Offset.zero; // X: Base, Y: Shoulder
  Offset _joy2Offset = Offset.zero; // X: Elbow, Y: Gripper

  // Periodic timer for continuous smooth servo jogging
  Timer? _jogTimer;
  DateTime _lastTick = DateTime.now();

  // Speed level: 0..10 (where 10 = 'q' max)
  int _speedLevel = 10;

  @override
  void initState() {
    super.initState();
    _bt.addListener(_onBtChanged);
    _startJogTimer();
  }

  @override
  void dispose() {
    _driveRepeatTimer?.cancel();
    _jogTimer?.cancel();
    _bt.removeListener(_onBtChanged);
    super.dispose();
  }

  void _onBtChanged() {
    if (!mounted) return;
    setState(() {});

    if (_bt.connectionState == bt.ConnectionState.disconnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Connection lost'),
          backgroundColor: Colors.redAccent.shade700,
          action: SnackBarAction(
            label: 'Reconnect',
            textColor: Colors.white,
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const ConnectionPage()),
              );
            },
          ),
        ),
      );
    }
  }

  void _startJogTimer() {
    _lastTick = DateTime.now();
    _jogTimer = Timer.periodic(const Duration(milliseconds: 35), (_) {
      _processArmInputs();
    });
  }

  void _processArmInputs() {
    final now = DateTime.now();
    final dt = now.difference(_lastTick).inMicroseconds / 1000000.0;
    _lastTick = now;

    if (_armMode == ArmControlMode.jog) {
      bool changed = false;

      // Joy 1: Base (X) & Shoulder (Y)
      if (_joy1Offset.dx.abs() > 5) {
        final dBase = (_joy1Offset.dx / 100.0) * _jogSpeedDegPerSec * dt;
        _servoAngles[0] = (_servoAngles[0] + dBase).clamp(0.0, 180.0);
        changed = true;
      }
      if (_joy1Offset.dy.abs() > 5) {
        final dShoulder = (_joy1Offset.dy / 100.0) * _jogSpeedDegPerSec * dt;
        _servoAngles[1] = (_servoAngles[1] + dShoulder).clamp(0.0, 180.0);
        changed = true;
      }

      // Joy 2: Elbow (X) & Gripper (Y)
      if (_joy2Offset.dx.abs() > 5) {
        final dElbow = (_joy2Offset.dx / 100.0) * _jogSpeedDegPerSec * dt;
        _servoAngles[2] = (_servoAngles[2] + dElbow).clamp(0.0, 180.0);
        changed = true;
      }
      if (_joy2Offset.dy.abs() > 5) {
        final dGripper = (_joy2Offset.dy / 100.0) * _jogSpeedDegPerSec * dt;
        _servoAngles[3] = (_servoAngles[3] + dGripper).clamp(0.0, 180.0);
        changed = true;
      }

      if (changed) {
        _syncServos();
      }
    }
  }

  void _syncServos() {
    for (int i = 0; i < 4; i++) {
      final target = _servoAngles[i].round().clamp(0, 180);
      if (target != _lastSentAngles[i]) {
        _lastSentAngles[i] = target;
        final cmd = String.fromCharCode('a'.codeUnitAt(0) + i);
        _bt.sendLine('$cmd$target');
      }
    }
    if (mounted) setState(() {});
  }

  // ---- D-Pad Movement ----
  // Continuously re-sends the active command every 150ms while held.
  // When released, sends 'S' burst and stops the repeat timer.
  // The firmware's 500ms timeout is the ultimate safety net.
  void _sendDrive(String cmd) {
    _activeDriveCmd = cmd;
    _bt.sendChar(cmd);

    // Start continuous re-send timer
    _driveRepeatTimer?.cancel();
    _driveRepeatTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (_activeDriveCmd != null) {
          _bt.sendChar(_activeDriveCmd!);
        }
      },
    );

    setState(() => _activeDpadButton = cmd);
  }

  void _sendStop() {
    _activeDriveCmd = null;
    _driveRepeatTimer?.cancel();
    _driveRepeatTimer = null;

    // Burst 3 stops to maximise chance of delivery
    _bt.sendChar('S');
    _bt.sendChar('S');
    _bt.sendChar('S');

    setState(() => _activeDpadButton = null);
  }

  // ---- Speed Control (0-9, q) ----
  void _setSpeed(int level) {
    setState(() => _speedLevel = level);
    if (level >= 10) {
      _bt.sendChar('q');
    } else {
      _bt.sendChar('$level');
    }
  }

  // ---- Arm Home (P) ----
  void _armHome() {
    _bt.sendChar('P');
    setState(() {
      for (int i = 0; i < 4; i++) {
        _servoAngles[i] = 90.0;
        _lastSentAngles[i] = 90;
      }
    });
  }

  // ---- Micro-trim adjustment ----
  void _trimServo(int index, double delta) {
    _servoAngles[index] = (_servoAngles[index] + delta).clamp(0.0, 180.0);
    _syncServos();
  }

  // ---- Quick Gripper Presets ----
  void _setGripper(double angle) {
    _servoAngles[3] = angle.clamp(0.0, 180.0);
    _syncServos();
  }

  // ---- Joystick callbacks ----
  void _onJoy1Changed(Offset offset) {
    _joy1Offset = offset;
    if (_armMode == ArmControlMode.direct) {
      _servoAngles[0] = (90 + (offset.dx / 100.0) * 90).clamp(0.0, 180.0);
      _servoAngles[1] = (90 + (offset.dy / 100.0) * 90).clamp(0.0, 180.0);
      _syncServos();
    }
  }

  void _onJoy2Changed(Offset offset) {
    _joy2Offset = offset;
    if (_armMode == ArmControlMode.direct) {
      _servoAngles[2] = (90 + (offset.dx / 100.0) * 90).clamp(0.0, 180.0);
      _servoAngles[3] = (90 + (offset.dy / 100.0) * 90).clamp(0.0, 180.0);
      _syncServos();
    }
  }

  void _disconnect() async {
    await _bt.disconnect();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ConnectionPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        // Global pointer-up catcher: if ANY finger lifts while driving, stop.
        onPointerUp: (_) {
          if (_activeDriveCmd != null) _sendStop();
        },
        onPointerCancel: (_) {
          if (_activeDriveCmd != null) _sendStop();
        },
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF090D1C), Color(0xFF0F1A30), Color(0xFF0A0F22)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Row(
                      children: [
                        // LEFT PANEL: 8-Direction D-Pad + Speed Slider
                        Expanded(
                          flex: 3,
                          child: _buildDrivePanel(),
                        ),
                        const SizedBox(width: 8),

                        // CENTER PANEL: Joystick 1 (Base & Shoulder)
                        Expanded(
                          flex: 3,
                          child: _buildArmJoy1Panel(),
                        ),
                        const SizedBox(width: 8),

                        // RIGHT PANEL: Joystick 2 (Elbow & Gripper)
                        Expanded(
                          flex: 3,
                          child: _buildArmJoy2Panel(),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // =========================================================================
  //  TOP BAR
  // =========================================================================
  Widget _buildTopBar() {
    final connected = _bt.isConnected;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1426),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2B48), width: 1)),
      ),
      child: Row(
        children: [
          // Connection LED indicator
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? const Color(0xFF00E676) : Colors.redAccent,
              boxShadow: [
                BoxShadow(
                  color: (connected ? const Color(0xFF00E676) : Colors.redAccent)
                      .withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            connected
                ? (_bt.connectedDeviceName ?? 'RampBot')
                : 'Disconnected',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),

          // Arm Mode Toggle (Jog / Direct)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF16213B),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF26385C)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildModeTab('HOLD (JOG)', ArmControlMode.jog),
                _buildModeTab('DIRECT', ArmControlMode.direct),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Home Button
          InkWell(
            onTap: _armHome,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF4081), Color(0xFFE040FB)],
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF4081).withValues(alpha: 0.3),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.home_rounded, size: 14, color: Colors.white),
                  SizedBox(width: 4),
                  Text(
                    'HOME (90°)',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Last Command Badge
          if (_bt.lastCommand.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                'CMD: ${_bt.lastCommand}',
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 10,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 10),

          // Disconnect Button
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.bluetooth_disabled_rounded,
                size: 18, color: Colors.redAccent),
            tooltip: 'Disconnect',
            onPressed: _disconnect,
          ),
        ],
      ),
    );
  }

  Widget _buildModeTab(String title, ArmControlMode mode) {
    final active = _armMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _armMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF00E5FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: active ? const Color(0xFF0A0E21) : Colors.white60,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  // =========================================================================
  //  LEFT PANEL: D-PAD & SPEED
  // =========================================================================
  Widget _buildDrivePanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF10172D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1C2B4C)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          const Text(
            'DRIVE MOVEMENT',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 2),

          // 8-Direction D-Pad
          SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              children: [
                // Stop in Center
                Center(
                  child: _buildDPadBtn(
                    icon: Icons.stop_rounded,
                    cmd: 'S',
                    tooltip: 'STOP (S)',
                    size: 42,
                    isStop: true,
                  ),
                ),
                // Forward (F)
                Positioned(
                  top: 0,
                  left: 58,
                  child: _buildDPadBtn(
                    icon: Icons.keyboard_arrow_up_rounded,
                    cmd: 'F',
                    tooltip: 'Forward',
                  ),
                ),
                // Backward (B)
                Positioned(
                  bottom: 0,
                  left: 58,
                  child: _buildDPadBtn(
                    icon: Icons.keyboard_arrow_down_rounded,
                    cmd: 'B',
                    tooltip: 'Backward',
                  ),
                ),
                // Left (L)
                Positioned(
                  left: 0,
                  top: 58,
                  child: _buildDPadBtn(
                    icon: Icons.keyboard_arrow_left_rounded,
                    cmd: 'L',
                    tooltip: 'Spin Left',
                  ),
                ),
                // Right (R)
                Positioned(
                  right: 0,
                  top: 58,
                  child: _buildDPadBtn(
                    icon: Icons.keyboard_arrow_right_rounded,
                    cmd: 'R',
                    tooltip: 'Spin Right',
                  ),
                ),
                // Fwd-Left (G)
                Positioned(
                  top: 8,
                  left: 8,
                  child: _buildDPadBtn(
                    icon: Icons.north_west_rounded,
                    cmd: 'G',
                    tooltip: 'Fwd-Left',
                    size: 36,
                  ),
                ),
                // Fwd-Right (I)
                Positioned(
                  top: 8,
                  right: 8,
                  child: _buildDPadBtn(
                    icon: Icons.north_east_rounded,
                    cmd: 'I',
                    tooltip: 'Fwd-Right',
                    size: 36,
                  ),
                ),
                // Back-Left (H)
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: _buildDPadBtn(
                    icon: Icons.south_west_rounded,
                    cmd: 'H',
                    tooltip: 'Back-Left',
                    size: 36,
                  ),
                ),
                // Back-Right (J)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: _buildDPadBtn(
                    icon: Icons.south_east_rounded,
                    cmd: 'J',
                    tooltip: 'Back-Right',
                    size: 36,
                  ),
                ),
              ],
            ),
          ),

          // Speed Control Slider
          _buildSpeedBar(),
        ],
      ),
    );
  }

  Widget _buildDPadBtn({
    required IconData icon,
    required String cmd,
    required String tooltip,
    double size = 44,
    bool isStop = false,
  }) {
    final isActive = _activeDpadButton == cmd;
    return Listener(
      onPointerDown: (_) => isStop ? _sendStop() : _sendDrive(cmd),
      onPointerUp: (_) { if (!isStop) _sendStop(); },
      onPointerCancel: (_) { if (!isStop) _sendStop(); },
      child: Tooltip(
        message: tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.28),
            color: isActive
                ? (isStop
                    ? Colors.redAccent.withValues(alpha: 0.5)
                    : const Color(0xFF00E5FF).withValues(alpha: 0.35))
                : (isStop
                    ? const Color(0xFF2C161B)
                    : const Color(0xFF16233E)),
            border: Border.all(
              color: isActive
                  ? (isStop ? Colors.redAccent : const Color(0xFF00E5FF))
                  : (isStop
                      ? Colors.redAccent.withValues(alpha: 0.5)
                      : const Color(0xFF283A61)),
              width: isActive ? 2 : 1,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: (isStop
                              ? Colors.redAccent
                              : const Color(0xFF00E5FF))
                          .withValues(alpha: 0.4),
                      blurRadius: 10,
                    )
                  ]
                : null,
          ),
          child: Icon(
            icon,
            color: isActive
                ? (isStop ? Colors.white : const Color(0xFF00E5FF))
                : (isStop ? Colors.redAccent : Colors.white70),
            size: size * 0.56,
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'SPEED: ',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _speedLevel >= 10 ? 'MAX (q)' : '$_speedLevel / 9',
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: const Color(0xFF00E5FF),
              inactiveTrackColor: const Color(0xFF1B2745),
              thumbColor: const Color(0xFF00E5FF),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              trackHeight: 3,
            ),
            child: Slider(
              min: 0,
              max: 10,
              divisions: 10,
              value: _speedLevel.toDouble(),
              onChanged: (v) => _setSpeed(v.round()),
            ),
          ),
        ),
      ],
    );
  }

  // =========================================================================
  //  CENTER PANEL: JOYSTICK 1 (BASE & SHOULDER)
  // =========================================================================
  Widget _buildArmJoy1Panel() {
    final baseAngle = _servoAngles[0].round();
    final shoulderAngle = _servoAngles[1].round();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF10172D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1C2B4C)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Header Readouts
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildServoBadge('BASE (a)', '$baseAngle°', const Color(0xFF00E5FF)),
              _buildServoBadge('SHOULDER (b)', '$shoulderAngle°', const Color(0xFF76FF03)),
            ],
          ),

          // Center Joystick
          Center(
            child: JoystickWidget(
              size: 135,
              label: 'JOYSTICK 1',
              verticalLabel: '▲ SHOULDER ↕ ▼',
              horizontalLabel: '◄ BASE ↔ ►',
              knobColor: const Color(0xFF00E5FF),
              baseColor: const Color(0xFF141D35),
              onChanged: _onJoy1Changed,
            ),
          ),

          // Precision Micro-Trim Buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildTrimGroup('Base', 0, const Color(0xFF00E5FF)),
              _buildTrimGroup('Shoulder', 1, const Color(0xFF76FF03)),
            ],
          ),
        ],
      ),
    );
  }

  // =========================================================================
  //  RIGHT PANEL: JOYSTICK 2 (ELBOW & GRIPPER)
  // =========================================================================
  Widget _buildArmJoy2Panel() {
    final elbowAngle = _servoAngles[2].round();
    final gripperAngle = _servoAngles[3].round();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF10172D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1C2B4C)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Header Readouts
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildServoBadge('ELBOW (c)', '$elbowAngle°', const Color(0xFFFFAB40)),
              _buildServoBadge('GRIPPER (d)', '$gripperAngle°', const Color(0xFFFF4081)),
            ],
          ),

          // Center Joystick
          Center(
            child: JoystickWidget(
              size: 135,
              label: 'JOYSTICK 2',
              verticalLabel: '▲ GRIPPER ↕ ▼',
              horizontalLabel: '◄ ELBOW ↔ ►',
              knobColor: const Color(0xFFFFAB40),
              baseColor: const Color(0xFF141D35),
              onChanged: _onJoy2Changed,
            ),
          ),

          // Quick Gripper Buttons + Elbow Trim
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildTrimGroup('Elbow', 2, const Color(0xFFFFAB40)),
              // Gripper Quick Open / Close
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildQuickActionBtn('OPEN', 30, const Color(0xFFFF4081)),
                  const SizedBox(width: 4),
                  _buildQuickActionBtn('CLOSE', 150, const Color(0xFFFF4081)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- Badges and Trim Helpers ----
  Widget _buildServoBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color: color.withValues(alpha: 0.9),
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrimGroup(String label, int servoIndex, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF141D35),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF213054)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => _trimServo(servoIndex, -5),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.remove, size: 12, color: color),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              label,
              style: TextStyle(
                color: color.withValues(alpha: 0.8),
                fontSize: 8,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          InkWell(
            onTap: () => _trimServo(servoIndex, 5),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.add, size: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionBtn(String text, double angle, Color color) {
    return InkWell(
      onTap: () => _setGripper(angle),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 8,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

