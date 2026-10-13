import 'package:flutter/widgets.dart';

/// Observador de rutas de la app (MaterialApp.navigatorObservers). Lo usan
/// las pantallas que deben recargarse al volver a ellas (p. ej. las métricas
/// de Home tras crear o editar algo en otra pantalla o en un diálogo).
final RouteObserver<ModalRoute<dynamic>> crmRouteObserver = RouteObserver<ModalRoute<dynamic>>();
