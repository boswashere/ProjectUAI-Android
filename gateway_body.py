"""Bounded HTTP request-body decoding; no credentials or payloads are logged."""
import re
import time


class UploadError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code


def read_request_body(headers, reader, limit, entry, set_timeout, budget=30):
    """Decode one unambiguous Content-Length or chunked body within size/time limits."""
    lengths = headers.get_all('Content-Length', [])
    encodings = headers.get_all('Transfer-Encoding', [])
    entry['request_bytes'] = 0
    entry['request_framing'] = 'none'

    def invalid(message='Invalid request framing'):
        raise UploadError(400, 'invalid_request_framing', message)

    def too_large():
        raise UploadError(413, 'request_too_large', 'Request body exceeds the gateway upload limit')

    if len(lengths) > 1 or len(encodings) > 1 or (lengths and encodings):
        entry['request_framing'] = 'ambiguous'
        invalid()
    if encodings:
        entry['request_framing'] = 'chunked'
        if encodings[0].strip().lower() != 'chunked':
            invalid('Unsupported transfer encoding')
    elif lengths:
        entry['request_framing'] = 'content-length'
        value = lengths[0].strip()
        if not re.fullmatch(r'[0-9]+', value):
            invalid('Invalid Content-Length')
        if len(value) > 20:
            too_large()
        length = int(value)
        entry['declared_bytes'] = length
        if length > limit:
            too_large()
    else:
        return b''

    deadline = time.monotonic() + budget

    def read(size, line=False):
        if line:
            value = bytearray()
            while len(value) < size:
                fragment = read(1)
                value.extend(fragment)
                if not fragment or fragment == b'\n':
                    break
            return bytes(value)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise UploadError(408, 'request_upload_timeout', 'Request upload timed out')
        set_timeout(remaining)
        try:
            # BufferedReader.read/readline can perform many socket reads, each
            # resetting an idle timeout. read1 lets us enforce one absolute
            # budget even when a client continually drips a few bytes.
            data = reader.read1(size)
        except TimeoutError as exc:
            raise UploadError(408, 'request_upload_timeout', 'Request upload timed out') from exc
        if time.monotonic() >= deadline:
            raise UploadError(408, 'request_upload_timeout', 'Request upload timed out')
        return data

    body = bytearray()

    def append(size):
        while size:
            data = read(min(size, 64 * 1024))
            if not data:
                raise UploadError(400, 'incomplete_request_body', 'Request body ended before its declared size')
            body.extend(data)
            entry['request_bytes'] += len(data)
            size -= len(data)

    if lengths:
        append(length)
        return bytes(body)

    # Bound framing overhead as well as decoded bytes. Chunk extensions and
    # harmless trailers are consumed, never forwarded as upstream headers.
    for _ in range(65536):
        line = read(1025, line=True)
        match = re.fullmatch(rb'([0-9a-fA-F]+)(?:;[^\r\n]*)?\r\n', line)
        if len(line) > 1024 or not match:
            invalid('Invalid chunk size')
        size = int(match[1], 16)
        if size > limit - len(body):
            too_large()
        if not size:
            trailer_bytes = 0
            while True:
                line = read(1025, line=True)
                trailer_bytes += len(line)
                if len(line) > 1024 or trailer_bytes > 8192:
                    invalid('Request trailers exceed framing limits')
                if line == b'\r\n':
                    return bytes(body)
                if not re.fullmatch(rb"[!#$%&'*+.^_`|~0-9a-zA-Z-]+:[^\r\n]*\r\n", line):
                    invalid('Invalid request trailer')
                if line.split(b':', 1)[0].lower() in {
                        b'content-length', b'transfer-encoding', b'authorization', b'host', b'trailer'}:
                    invalid('Forbidden request trailer')
        append(size)
        if read(1) + read(1) != b'\r\n':
            invalid('Invalid chunk terminator')
    invalid('Too many request chunks')
