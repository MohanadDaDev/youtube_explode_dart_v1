import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

/// Replaces the old caption fetch logic using reliable InnerTube method
class ClosedCaptionClient {
  final xml.XmlDocument root;

  late final Iterable<ClosedCaption> closedCaptions =
      root.findAllElements('p').map((e) => ClosedCaption._(e));

  ClosedCaptionClient(this.root);

  ClosedCaptionClient.parse(String raw) : root = xml.XmlDocument.parse(raw);

  /// Main function to call: uses InnerTube to get caption XML and parse it
  static Future<ClosedCaptionClient> get(dynamic _, Uri url) async {
    final videoId = _extractVideoId(url.toString());

    final html = await _fetchVideoHtml(videoId);
    final apiKey = _extractApiKey(html, videoId);

    final innerTubeResponse = await _fetchInnertubeData(videoId, apiKey);
    final captions = innerTubeResponse['captions']
        ?['playerCaptionsTracklistRenderer']?['captionTracks'];

    if (captions == null || captions.isEmpty) {
      throw Exception('No captions found for this video');
    }

    // Pick the first caption track by default
    final captionUrl = captions[0]['baseUrl'];

    final captionXml = await _fetchCaptionXml(captionUrl);

    return ClosedCaptionClient.parse(captionXml);
  }

  // Internal helper methods
  static String _extractVideoId(String input) {
    final patterns = [
      RegExp(
          r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([^&?/]+)'),
      RegExp(r'[?&]v=([^&]+)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(input);
      if (match != null) return match.group(1)!;
    }

    if (!input.contains('/') && !input.contains('youtube')) {
      return input; // fallback to assuming it's the ID
    }

    throw Exception('Invalid YouTube URL: $input');
  }

  static Future<String> _fetchVideoHtml(String videoId) async {
    final response = await http.get(
      Uri.parse('https://www.youtube.com/watch?v=$videoId'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept-Language': 'en-US,en;q=0.9',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch video HTML');
    }

    return response.body;
  }

  static String _extractApiKey(String html, String videoId) {
    final match =
        RegExp(r'"INNERTUBE_API_KEY":"([a-zA-Z0-9_\-]+)"').firstMatch(html);
    if (match != null) return match.group(1)!;

    if (html.contains('class="g-recaptcha"')) {
      throw Exception('YouTube blocked your IP for $videoId');
    }

    throw Exception('Failed to extract InnerTube API key');
  }

  static Future<Map<String, dynamic>> _fetchInnertubeData(
      String videoId, String apiKey) async {
    final response = await http.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/player?key=$apiKey'),
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
      throw Exception('Failed to fetch InnerTube response');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<String> _fetchCaptionXml(String captionUrl) async {
    final response = await http.get(
      Uri.parse(captionUrl),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch captions from $captionUrl');
    }

    return response.body;
  }
}

class ClosedCaption {
  final xml.XmlElement root;

  /// The text content of the caption.
  String get text => root.innerText;

  /// Start time of the caption.
  late final Duration offset = Duration(
      milliseconds:
          (double.tryParse(root.getAttribute('start') ?? '0')! * 1000).round());

  /// Duration of the caption.
  late final Duration duration = Duration(
      milliseconds:
          (double.tryParse(root.getAttribute('dur') ?? '0')! * 1000).round());

  /// End time = offset + duration
  late final Duration end = offset + duration;

  /// No parts in <text> style captions, keep empty list for compatibility
  late final List<ClosedCaptionPart> parts = [];

  ClosedCaption._(this.root);
}

///
/// Represents a part of a closed caption (unused for <text> tags)
class ClosedCaptionPart {
  final xml.XmlElement root;

  String get text => root.innerText;

  late final Duration offset =
      Duration(milliseconds: int.parse(root.getAttribute('t') ?? '0'));

  ClosedCaptionPart._(this.root);
}
