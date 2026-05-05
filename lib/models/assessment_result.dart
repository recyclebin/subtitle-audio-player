class AssessmentResult {
  final String referenceText;
  final String recognizedText;
  final double overallScore;
  final double accuracyScore;
  final double fluencyScore;
  final double completenessScore;
  final List<WordResult> words;
  final String? language;

  const AssessmentResult({
    required this.referenceText,
    required this.recognizedText,
    required this.overallScore,
    this.accuracyScore = 0,
    this.fluencyScore = 0,
    this.completenessScore = 0,
    required this.words,
    this.language,
  });

  factory AssessmentResult.fromAzureResponse(
    Map<String, dynamic> json,
    String referenceText, {
    String? language,
  }) {
    final nbestList = json['NBest'] as List?;
    if (nbestList == null || nbestList.isEmpty) {
      return AssessmentResult(
        referenceText: referenceText,
        recognizedText: '',
        overallScore: 0,
        words: [],
        language: language,
      );
    }
    final nbest = nbestList.first as Map<String, dynamic>;
    final recognizedText = nbest['Lexical'] as String? ?? '';
    final overallScore = (nbest['PronScore'] as num?)?.toDouble() ?? 0;
    final accuracyScore = (nbest['AccuracyScore'] as num?)?.toDouble() ?? 0;
    final fluencyScore = (nbest['FluencyScore'] as num?)?.toDouble() ?? 0;
    final completenessScore = (nbest['CompletenessScore'] as num?)?.toDouble() ?? 0;

    final wordsJson = (nbest['Words'] as List?) ?? [];
    final words = <WordResult>[];
    for (final w in wordsJson) {
      final map = w as Map<String, dynamic>;
      final errorType = map['ErrorType'] as String?;
      final phonemesJson = (map['Phonemes'] as List?) ?? [];
      final phonemes = <PhonemeResult>[];
      for (final p in phonemesJson) {
        final pm = p as Map<String, dynamic>;
        phonemes.add(PhonemeResult(
          phoneme: pm['Phoneme'] as String? ?? '',
          score: (pm['AccuracyScore'] as num?)?.toDouble() ?? 0,
        ));
      }
      words.add(WordResult(
        word: map['Word'] as String? ?? '',
        accuracyScore: (map['AccuracyScore'] as num?)?.toDouble() ?? 0,
        isOmission: errorType == 'Omission',
        isInsertion: errorType == 'Insertion',
        phonemes: phonemes,
      ));
    }

    return AssessmentResult(
      referenceText: referenceText,
      recognizedText: recognizedText,
      overallScore: overallScore,
      accuracyScore: accuracyScore,
      fluencyScore: fluencyScore,
      completenessScore: completenessScore,
      words: words,
      language: language,
    );
  }

  Map<String, dynamic> toJson() => {
        'referenceText': referenceText,
        'recognizedText': recognizedText,
        'overallScore': overallScore,
        'accuracyScore': accuracyScore,
        'fluencyScore': fluencyScore,
        'completenessScore': completenessScore,
        'words': words.map((w) => w.toJson()).toList(),
        if (language != null) 'language': language,
      };

  factory AssessmentResult.fromJson(Map<String, dynamic> json) {
    final wordsJson = (json['words'] as List?) ?? [];
    return AssessmentResult(
      referenceText: json['referenceText'] as String? ?? '',
      recognizedText: json['recognizedText'] as String? ?? '',
      overallScore: (json['overallScore'] as num?)?.toDouble() ?? 0,
      accuracyScore: (json['accuracyScore'] as num?)?.toDouble() ?? 0,
      fluencyScore: (json['fluencyScore'] as num?)?.toDouble() ?? 0,
      completenessScore:
          (json['completenessScore'] as num?)?.toDouble() ?? 0,
      words: wordsJson
          .map((w) => WordResult.fromJson(w as Map<String, dynamic>))
          .toList(),
      language: json['language'] as String?,
    );
  }
}

class WordResult {
  final String word;
  final double accuracyScore;
  final bool isOmission;
  final bool isInsertion;
  final List<PhonemeResult> phonemes;

  const WordResult({
    required this.word,
    required this.accuracyScore,
    required this.isOmission,
    required this.isInsertion,
    required this.phonemes,
  });

  Map<String, dynamic> toJson() => {
        'word': word,
        'accuracyScore': accuracyScore,
        'isOmission': isOmission,
        'isInsertion': isInsertion,
        'phonemes': phonemes.map((p) => p.toJson()).toList(),
      };

  factory WordResult.fromJson(Map<String, dynamic> json) {
    final phonemesJson = (json['phonemes'] as List?) ?? [];
    return WordResult(
      word: json['word'] as String? ?? '',
      accuracyScore: (json['accuracyScore'] as num?)?.toDouble() ?? 0,
      isOmission: json['isOmission'] as bool? ?? false,
      isInsertion: json['isInsertion'] as bool? ?? false,
      phonemes: phonemesJson
          .map((p) => PhonemeResult.fromJson(p as Map<String, dynamic>))
          .toList(),
    );
  }
}

class PhonemeResult {
  final String phoneme;
  final double score;

  const PhonemeResult({
    required this.phoneme,
    required this.score,
  });

  Map<String, dynamic> toJson() => {
        'phoneme': phoneme,
        'score': score,
      };

  factory PhonemeResult.fromJson(Map<String, dynamic> json) => PhonemeResult(
        phoneme: json['phoneme'] as String? ?? '',
        score: (json['score'] as num?)?.toDouble() ?? 0,
      );
}
