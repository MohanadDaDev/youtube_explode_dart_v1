import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

/// Represents a closed caption track with XML parsing.
class ClosedCaptionClient {
  final xml.XmlDocument root;

  /// All parsed captions (p elements).
  late final Iterable<ClosedCaption> closedCaptions =
      root.findAllElements('p').map((e) => ClosedCaption._(e));

  /// Constructor from XML root.
  ClosedCaptionClient(this.root);

  /// Construct from raw XML string.
  ClosedCaptionClient.parse(String raw) : root = xml.XmlDocument.parse(raw);

  /// Main entry point — fetches captions from YouTube via InnerTube API.
  static Future<ClosedCaptionClient> get(
    dynamic _,
    Uri inputUrl,
  ) async {
    String? videoId;

    // Try to extract video ID from URL or assume it's an ID
    final inputStr = inputUrl.toString();
    final patterns = [
      RegExp(r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/)([^&?/]+)'),
      RegExp(r'[?&]v=([^&]+)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(inputStr);
      if (match != null) {
        videoId = match.group(1);
        break;
      }
    }

    if (videoId == null && !inputStr.contains('/')) {
      videoId = inputStr;
    }

    if (videoId == null) {
      throw Exception('Could not extract YouTube video ID from input: $inputStr');
    }

    // Step 1: Fetch video page HTML
    final htmlResponse = await http.get(
      Uri.parse('https://www.youtube.com/watch?v=$videoId'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept-Language': 'en-US,en;q=0.9',
      },
    );

    if (htmlResponse.statusCode != 200) {
      throw Exception('Failed to load YouTube video page');
    }

    final html = htmlResponse.body;

    // Step 2: Extract API key from HTML
    final apiKeyMatch =
        RegExp(r'"INNERTUBE_API_KEY":"([a-zA-Z0-9_\-]+)"').firstMatch(html);
    if (apiKeyMatch == null) {
      throw Exception('Failed to extract InnerTube API key from HTML');
    }
    final apiKey = apiKeyMatch.group(1)!;

    // Step 3: Fetch InnerTube player data
    final innerTubeResponse = await http.post(
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

    if (innerTubeResponse.statusCode != 200) {
      throw Exception('Failed to fetch InnerTube player data');
    }

    final json = jsonDecode(innerTubeResponse.body);
    final captionsData = json['captions']?['playerCaptionsTracklistRenderer'];
    final captionTracks = captionsData?['captionTracks'];

    if (captionTracks == null || captionTracks.isEmpty) {
      throw Exception('No captions found for this video');
    }

    // Step 4: Pick the first caption track (or use language match if needed)
    final track = captionTracks[0];
    final captionUrl = track['baseUrl'];

    // Step 5: Fetch the actual caption XML
    final captionXmlRes = await http.get(
      Uri.parse(captionUrl),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Accept': '*/*',
      },
    );

    if (captionXmlRes.statusCode != 200 || captionXmlRes.body.isEmpty) {
      throw Exception('Failed to fetch caption XML');
    }

    return ClosedCaptionClient.parse(captionXmlRes.body);
  }
}

/// Represents a single caption <p> element.
class ClosedCaption {
  final xml.XmlElement root;

  /// Full caption text.
  String get text => root.innerText;

  /// Start time offset.
  late final Duration offset =
      Duration(milliseconds: int.parse(root.getAttribute('t') ?? '0'));

  /// Duration of this caption.
  late final Duration duration =
      Duration(milliseconds: int.parse(root.getAttribute('d') ?? '0'));

  /// End time = offset + duration.
  late final Duration end = offset + duration;

  /// Parts (individual <s> elements).
  late final List<ClosedCaptionPart> parts =
      root.findAllElements('s').map((e) => ClosedCaptionPart._(e)).toList();

  ClosedCaption._(this.root);
}

/// Represents a single word or segment <s> element inside a caption.
class ClosedCaptionPart {
  final xml.XmlElement root;

  /// Word or segment text.
  String get text => root.innerText;

  /// Offset time relative to start.
  late final Duration offset =
      Duration(milliseconds: int.parse(root.getAttribute('t') ?? '0'));

  ClosedCaptionPart._(this.root);
}
