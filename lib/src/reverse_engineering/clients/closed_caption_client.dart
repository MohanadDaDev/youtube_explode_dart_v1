import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../../../youtube_explode_dart.dart';

/// Client to fetch and parse closed captions from YouTube using InnerTube API.
class ClosedCaptionClient {
  final xml.XmlDocument root;

  /// List of parsed captions from XML.
  late final Iterable<ClosedCaption> closedCaptions =
      root.findAllElements('text').map((e) => ClosedCaption._(e));

  ClosedCaptionClient(this.root);

  ClosedCaptionClient.parse(String raw) : root = xml.XmlDocument.parse(raw);

  static const _watchUrl = 'https://www.youtube.com/watch?v=';
  static const _innerTubeUrl =
      'https://www.youtube.com/youtubei/v1/player?key=';

  /// Fetches and parses caption XML using InnerTube API.
  static Future<ClosedCaptionClient> get(
    dynamic _,
    Uri url,
  ) async {
    final videoId = _extractVideoId(url.toString());
    final html = await _fetchVideoHtml(videoId);
    final apiKey = _extractApiKey(html);
    final captionUrl = await _getCaptionUrl(videoId, apiKey);

    final response = await http.get(Uri.parse(captionUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch caption XML');
    }

    final raw = response.body;
    return ClosedCaptionClient.parse(raw);
  }

  static String _extractVideoId(String url) {
    final patterns = [
      RegExp(
          r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([^&?/]+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null) return match.group(1)!;
    }

    if (!url.contains('/')) return url;

    throw Exception('Invalid YouTube URL: $url');
  }

  static Future<String> _fetchVideoHtml(String videoId) async {
    final res = await http.get(
      Uri.parse('$_watchUrl$videoId'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to fetch YouTube watch page');
    }

    return res.body;
  }

  static String _extractApiKey(String html) {
    final pattern = RegExp(r'"INNERTUBE_API_KEY":"([a-zA-Z0-9_-]+)"');
    final match = pattern.firstMatch(html);

    if (match != null && match.groupCount >= 1) {
      return match.group(1)!;
    }

    throw Exception('Failed to extract API key from HTML');
  }

  static Future<String> _getCaptionUrl(String videoId, String apiKey) async {
    final response = await http.post(
      Uri.parse('$_innerTubeUrl$apiKey'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
      body: jsonEncode({
        'context': {
          'client': {
            'hl': 'en',
            'gl': 'US',
            'clientName': 'WEB',
            'clientVersion': '2.20210721.00.00',
          }
        },
        'videoId': videoId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch player response from InnerTube');
    }

    final data = jsonDecode(response.body);
    final captions = data['captions']?['playerCaptionsTracklistRenderer'];
    if (captions == null || captions['captionTracks'] == null) {
      throw Exception('No captions found');
    }

    final tracks = List<Map<String, dynamic>>.from(captions['captionTracks']);
    return tracks.first['baseUrl'];
  }
}

/// Represents a single closed caption element from XML.
class ClosedCaption {
  final xml.XmlElement root;

  String get text => root.innerText;

  late final Duration offset = Duration(
    milliseconds:
        (double.tryParse(root.getAttribute('start') ?? '0')! * 1000).toInt(),
  );

  late final Duration duration = Duration(
    milliseconds:
        (double.tryParse(root.getAttribute('dur') ?? '0')! * 1000).toInt(),
  );

  late final Duration end = offset + duration;

  // These are not nested in <text> captions
  final List<ClosedCaptionPart> parts = [];

  ClosedCaption._(this.root);
}

/// Part of a closed caption (not used in <text>-based format, but kept for API
