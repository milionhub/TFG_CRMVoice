import 'package:flutter/material.dart';
import '../models/activity.dart';
import '../services/api_service.dart';

class ActivityProvider extends ChangeNotifier {
  List<Activity> _activities = [];
  bool _isLoading = false;

  List<Activity> get activities => _activities;
  bool get isLoading => _isLoading;

  Future<void> fetchActivities() async {
    _isLoading = true;
    notifyListeners();

    final response = await ApiService.getActivities();

    _activities = response
        .map<Activity>((json) => Activity.fromJson(json))
        .toList();

    _isLoading = false;
    notifyListeners();
  }
}