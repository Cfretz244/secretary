def extract_text(row: dict) -> str:
    """Extract message text from a chat.db row.

    Priority:
    1. message.text column (if non-null/non-empty)
    2. attributedBody blob — scan for embedded NSString
    3. Fallback placeholder
    """
    text = row.get("text")
    if text:
        return text

    blob = row.get("attributedBody")
    if blob and isinstance(blob, (bytes, bytearray)):
        return _extract_from_attributed_body(blob)

    return "[message content unavailable]"


def _extract_from_attributed_body(blob: bytes) -> str:
    """Extract UTF-8 text from an NSKeyedArchiver attributedBody blob.

    The text is stored as an NSString within the archive. We look for the
    pattern where the string length is encoded before the text content.
    """
    try:
        # Strategy: find "NSString" marker, then look for the text nearby.
        # The actual text is typically stored after a streamtyped header.
        # A reliable approach: scan for the byte sequence that precedes the
        # embedded string in NSKeyedArchiver format.

        # Look for NSMutableString or NSString class markers
        # The text typically appears after a specific byte pattern
        # Try to decode the largest UTF-8 substring we can find

        # Method: find chunks between null bytes, pick the longest valid UTF-8
        best = ""
        i = 0
        n = len(blob)
        while i < n:
            # Skip null bytes
            if blob[i] == 0:
                i += 1
                continue

            # Find the end of this non-null chunk
            j = i
            while j < n and blob[j] != 0:
                j += 1

            chunk = blob[i:j]
            if len(chunk) > len(best):
                try:
                    decoded = chunk.decode("utf-8", errors="strict")
                    # Filter out binary-looking strings
                    printable_ratio = sum(
                        1 for c in decoded if c.isprintable() or c in "\n\r\t"
                    ) / max(len(decoded), 1)
                    if printable_ratio > 0.8 and len(decoded) > len(best):
                        best = decoded
                except (UnicodeDecodeError, ValueError):
                    pass

            i = j

        if best:
            return best.strip()
    except Exception:
        pass

    return "[message content unavailable]"
