"""Every if, else, for, while and do of C and C++ has braces. clang-format's InsertBraces says where braces are missing and
this script adds them and nothing else, so no other line changes.
    braces.py --check FILE...   list each statement without braces, exit 1 if any (the prek hook)
    braces.py FILE...           insert the braces
Exit 2: clang-format could not be run."""
import difflib
import re
import subprocess
import sys
STYLE = '{BasedOnStyle: LLVM, InsertBraces: true, SortIncludes: Never, SortUsingDeclarations: Never, ColumnLimit: 0, ReflowComments: false}'

def lex(s):
    toks = []  # (text, start, end)
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c.isspace():
            i += 1
        elif s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2)
            i = n if j < 0 else j + 2
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == '\\' else 1
            toks.append((s[i:j + 1], i, j + 1))
            i = j + 1
        elif c.isalnum() or c == '_':
            j = i
            while j < n and (s[j].isalnum() or s[j] == '_' or s[j] == '.' and s[i].isdigit()):
                j += 1
            toks.append((s[i:j], i, j))
            i = j
        else:
            toks.append((c, i, i + 1))
            i += 1
    return toks

def line_of(s, off):
    return s.count('\n', 0, off)

def line_start(s, off):
    return s.rfind('\n', 0, off) + 1

def line_end(s, off):
    j = s.find('\n', off)
    return len(s) if j < 0 else j

def fix(path, check=False):
    src = open(path).read()
    try:
        done = subprocess.run(['clang-format', '--style=' + STYLE, path], capture_output=True, text=True)
    except FileNotFoundError:
        raise SystemExit('clang-format is not on the PATH')
    if done.returncode != 0:
        raise SystemExit(f'{path}: clang-format failed: {done.stderr.strip()[:200]}')
    out = done.stdout
    A, B = lex(src), lex(out)
    ta, tb = [t[0] for t in A], [t[0] for t in B]
    sm = difflib.SequenceMatcher(None, ta, tb, autojunk=False)
    ins_open = set()
    for tag, a0, a1, b0, b1 in sm.get_opcodes():
        if tag == 'equal':
            continue
        if tag != 'insert':
            raise SystemExit(f'{path}: clang-format changed tokens {ta[a0:a1]} -> {tb[b0:b1]}')
        for k in range(b0, b1):
            if tb[k] not in ('{', '}'):
                raise SystemExit(f'{path}: clang-format inserted {tb[k]!r}, not a brace')
            if tb[k] == '{':
                ins_open.add(k)
    # An inserted closing brace is the one whose opener was inserted; the others of a run of closers are the file's own.
    stack, pairs, kept = [], [], []
    orig_pos = 0
    for k in range(len(tb)):
        if tb[k] == '{':
            stack.append(('ins', orig_pos) if k in ins_open else ('orig', 0))
            if k not in ins_open:
                kept.append(tb[k]); orig_pos += 1
        elif tb[k] == '}':
            kind, op = stack.pop() if stack else ('orig', 0)
            if kind == 'ins':
                pairs.append((op, orig_pos))
            else:
                kept.append(tb[k]); orig_pos += 1
        else:
            kept.append(tb[k]); orig_pos += 1
    if kept != ta:
        raise SystemExit(f'{path}: the tokens that are not insertions differ from the file')
    if check:
        for op, _ in sorted(pairs):
            print(f'{path}:{line_of(src, A[op][1]) + 1}: a control statement has no braces')
        return len(pairs)
    edits = []  # (offset, seq, replace_end, text)
    seq = 0
    for op, cp in sorted(pairs, key=lambda p: (p[1], -p[0])):
        prev, first = A[op - 1], A[op]
        last, nxt = A[cp - 1], (A[cp] if cp < len(A) else None)
        same_open = '\n' not in src[prev[2]:first[1]]
        # keyword line, for the indent of a closing brace on its own line
        kw = prev
        if prev[0] == ')':
            depth, m = 0, op - 1
            while True:
                if A[m][0] == ')':
                    depth += 1
                elif A[m][0] == '(':
                    depth -= 1
                    if depth == 0:
                        break
                m -= 1
            kw = A[m - 1]
        indent = re.match(r'[ \t]*', src[line_start(src, kw[1]):]).group(0)
        if same_open:
            edits.append((first[1], seq, first[1], '{ '))
        else:
            edits.append((prev[2], seq, prev[2], ' {'))
        seq += 1
        one_line = line_of(src, first[1]) == line_of(src, last[2] - 1)
        next_same_line = nxt is not None and '\n' not in src[last[2]:nxt[1]]
        if (same_open and one_line) or next_same_line:
            edits.append((last[2], seq, last[2], ' }'))
        elif nxt is not None and nxt[0] == 'else':
            eol = line_end(src, last[2])
            edits.append((eol, seq, nxt[1], '\n' + indent + '} '))
        else:
            eol = line_end(src, last[2])
            edits.append((eol, seq, eol, '\n' + indent + '}'))
        seq += 1
    # apply from the end; edits at one offset keep their order
    by_pos = {}
    for off, sq, end, text in edits:
        by_pos.setdefault((off, end), []).append((sq, text))
    res = src
    for (off, end), items in sorted(by_pos.items(), key=lambda kv: (-kv[0][0], -kv[0][1])):
        res = res[:off] + ''.join(t for _, t in sorted(items)) + res[end:]
    open(path, 'w').write(res)
    # the check: the fixed file's tokens equal clang-format's
    if [t[0] for t in lex(res)] != tb:
        raise SystemExit(f'{path}: tokens differ from clang-format after the edit')
    return len(pairs)

if __name__ == '__main__':
    args = sys.argv[1:]
    check = bool(args) and args[0] == '--check'
    total = 0
    for p in args[1 if check else 0:]:
        total += fix(p, check)
    if check:
        sys.exit(1 if total else 0)
    print('braces inserted:', total)
