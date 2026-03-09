import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../widgets/recorder_card.dart';

class HomeContent extends StatefulWidget {
  const HomeContent({super.key});

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent> {
  bool isConnected = false;
  bool isChecking = true;

  @override
  void initState() {
    super.initState();
    _checkBackend();
  }

  Future<void> _checkBackend() async {
    try {
      final api = context.read<ApiService>();
      final message = await api.ping();

      setState(() {
        isConnected = message == "ok" || message.isNotEmpty;
        isChecking = false;
      });
    } catch (_) {
      setState(() {
        isConnected = false;
        isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isChecking && !isConnected)
          StatusCard(
            isConnected: isConnected,
            isChecking: isChecking,
          ),
          const SizedBox(height: 24),
          const Expanded(
            child: Center(
              child: RecorderCard(),
            ),
          ),
        ],
      ),
    );
  }
}

class StatusCard extends StatelessWidget {
  final bool isConnected;
  final bool isChecking;

  const StatusCard({
    super.key,
    required this.isConnected,
    required this.isChecking,
  });

  @override
  Widget build(BuildContext context) {
    Color iconColor;
    IconData icon;
    String text;

    if (isChecking) {
      iconColor = Colors.orange;
      icon = Icons.sync;
      text = "Comprobando conexión...";
    } else if (isConnected) {
      iconColor = const Color(0xFF1E88E5);
      icon = Icons.cloud_done;
      text = "Backend conectado";
    } else {
      iconColor = Colors.red;
      icon = Icons.cloud_off;
      text = "Backend desconectado";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          )
        ],
      ),
    );
  }
}