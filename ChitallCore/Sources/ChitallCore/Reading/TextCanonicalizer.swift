/// Turns the raw character data of a paragraph-like element into its canonical text — the
/// string that locator offsets count in. The rules are part of the locator format
/// (docs/locator.md) and must never change silently:
///
/// 1. Concatenate all descendant text nodes in document order.
/// 2. Remove soft hyphens (U+00AD).
/// 3. Replace every run of XML whitespace (U+0020, U+0009, U+000A, U+000D) with one U+0020.
/// 4. Trim the leading and trailing space.
///
/// Other characters, including no-break space U+00A0, are kept as is.
///
/// EPUB only (`keepsLineBreaks`): `<br>` arrives as U+2028 LINE SEPARATOR. Whitespace around
/// it is dropped, and so are line separators at the start and the end of the text, so a line
/// break never comes with stray spaces. FB2 text is canonicalized without this rule.
public struct TextCanonicalizer {
    public struct Segment: Sendable {
        public var text: String
        public var style: InlineStyle
        public var link: String?
        public var isNoteReference: Bool

        public init(text: String, style: InlineStyle = [], link: String? = nil, isNoteReference: Bool = false) {
            self.text = text
            self.style = style
            self.link = link
            self.isNoteReference = isNoteReference
        }
    }

    public struct Result: Sendable {
        public var text: String
        public var runs: [InlineRun]
    }

    public static func canonicalText(_ raw: String) -> String {
        canonicalize([Segment(text: raw)]).text
    }

    public static func canonicalize(_ segments: [Segment], keepsLineBreaks: Bool = false) -> Result {
        var output = String.UnicodeScalarView()
        var utf16Length = 0
        var runs: [InlineRun] = []
        // A collapsed space belongs to the run where the whitespace started.
        var pendingSpace: Segment?
        // Line separators wait for the next visible character (EPUB `<br>`).
        var pendingBreaks: [Segment] = []

        func emit(_ scalar: Unicode.Scalar, as segment: Segment) {
            let start = utf16Length
            output.append(scalar)
            utf16Length += scalar.utf16Width
            if var last = runs.last,
               last.range.upperBound == start,
               last.style == segment.style,
               last.link == segment.link,
               last.isNoteReference == segment.isNoteReference {
                last.range = last.range.lowerBound..<utf16Length
                runs[runs.count - 1] = last
            } else {
                runs.append(InlineRun(
                    range: start..<utf16Length,
                    style: segment.style,
                    link: segment.link,
                    isNoteReference: segment.isNoteReference
                ))
            }
        }

        for segment in segments {
            for scalar in segment.text.unicodeScalars {
                switch scalar {
                case "\u{00AD}":
                    continue
                case "\u{2028}" where keepsLineBreaks:
                    pendingSpace = nil
                    if !output.isEmpty { pendingBreaks.append(segment) }
                case " ", "\t", "\n", "\r":
                    if !output.isEmpty, pendingSpace == nil, pendingBreaks.isEmpty { pendingSpace = segment }
                default:
                    for owner in pendingBreaks { emit("\u{2028}", as: owner) }
                    pendingBreaks = []
                    if let spaceOwner = pendingSpace {
                        emit(" ", as: spaceOwner)
                        pendingSpace = nil
                    }
                    emit(scalar, as: segment)
                }
            }
        }

        // Runs without any styling carry no information for rendering.
        let styledRuns = runs.filter { !$0.style.isEmpty || $0.link != nil || $0.isNoteReference }
        return Result(text: String(output), runs: styledRuns)
    }
}
