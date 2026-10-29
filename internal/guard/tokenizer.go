// Package guard 实现 mysqlq 的只读防护：SQL 词法分析 + 默认拒绝的只读判定。
//
// 设计要点（SPEC §6）：
//   - 不使用正则做整体判断，而是把 SQL 拆成 token 后逐条按规则审核；
//   - 字符串字面量、反引号标识符里的内容不参与关键字判断；
//   - 词法上拿不准（未闭合字符串/注释、`/*!` 可执行注释）一律拦截。
package guard

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// TokenKind 是 token 的种类。
type TokenKind int

const (
	// KindWord 是裸单词：关键字或标识符（如 SELECT、sale_pay、中文列名）。
	KindWord TokenKind = iota
	// KindString 是字符串字面量（'...' 或 "..."）。
	KindString
	// KindQuotedIdent 是反引号标识符（`...`）。
	KindQuotedIdent
	// KindNumber 是数字字面量。
	KindNumber
	// KindPunct 是单字符标点/运算符。
	KindPunct
	// KindSemicolon 是语句分隔符 `;`。
	KindSemicolon
)

// Token 是词法单元，保留原始位置用于错误提示。
type Token struct {
	Kind TokenKind
	// Text 是原始文本（用于错误信息展示）。
	Text string
	// Word 仅 KindWord 有效：大写形式，用于白/黑名单匹配。
	Word string
	// Pos 是字节偏移；Line/Col 从 1 开始，用于人类可读的位置提示。
	Pos  int
	Line int
	Col  int
}

// SyntaxError 表示无法安全分词（未闭合字符串/注释等），按"默认拒绝"转成拦截。
type SyntaxError struct {
	Msg  string
	Line int
	Col  int
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("%s at line %d, column %d", e.Msg, e.Line, e.Col)
}

func isSpaceByte(c byte) bool {
	switch c {
	case ' ', '\t', '\r', '\n', '\f', '\v':
		return true
	}
	return false
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isLetter(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// isWordStart 判断单词起始：字母、下划线、$，以及 >=0x80 的 UTF-8 非 ASCII 字符。
func isWordStart(c byte) bool { return isLetter(c) || c == '_' || c == '$' || c >= 0x80 }

// isWordPart 判断单词后续字符：字母、数字、下划线、$，以及非 ASCII 字节。
func isWordPart(c byte) bool {
	return isLetter(c) || isDigit(c) || c == '_' || c == '$' || c >= 0x80
}

// isNumberPart 把数字字面量吃成一个 token（含 1.5、1e10、0xFF 等写法）。
func isNumberPart(c byte) bool {
	return isLetter(c) || isDigit(c) || c == '.' || c == '$' || c >= 0x80
}

// Tokenize 把 SQL 拆成 token 序列。
//
// 规则对应 SPEC §6.1：
//   - 跳过空白；
//   - 跳过 `-- `（-- 后必须跟空白或行尾）、`# ...`、`/* ... */` 注释；
//   - `/*!` 版本注释直接返回语法错误（MySQL 会执行其内容，不能当注释跳过）；
//   - `/*+` optimizer hint 按普通注释跳过；
//   - 正确处理字符串的 `\\` 转义与 `”` 双写、反引号的 ``` “ ``` 双写；
//   - `;` 单独成 token。
func Tokenize(sql string) ([]Token, error) {
	var toks []Token
	i, line, col := 0, 1, 1
	n := len(sql)

	adv := func(k int) {
		for j := 0; j < k && i < n; j++ {
			if sql[i] == '\n' {
				line++
				col = 1
			} else {
				col++
			}
			i++
		}
	}

	for i < n {
		c := sql[i]
		// 非 ASCII 的 Unicode 空白（如全角空格 U+3000）也按空白跳过，
		// 避免 "　INSERT ..." 被当成一个以空白开头的标识符。
		if c >= 0x80 {
			if r, size := utf8.DecodeRuneInString(sql[i:]); r != utf8.RuneError && unicode.IsSpace(r) {
				adv(size)
				continue
			}
		}
		switch {
		case isSpaceByte(c):
			adv(1)

		case c == '#': // # 注释到行尾
			for i < n && sql[i] != '\n' {
				adv(1)
			}

		case c == '-' && i+1 < n && sql[i+1] == '-' && (i+2 >= n || isSpaceByte(sql[i+2])):
			// MySQL 要求 `--` 后面跟空白或行尾才是注释；否则是两个减号运算符。
			for i < n && sql[i] != '\n' {
				adv(1)
			}

		case c == '/' && i+1 < n && sql[i+1] == '*':
			if i+2 < n && sql[i+2] == '!' {
				// 版本注释（versioned comment）会被 MySQL 执行，必须拦截。
				return nil, &SyntaxError{Msg: "versioned comment /*! ... */ is not allowed (MySQL executes its content)", Line: line, Col: col}
			}
			startLine, startCol := line, col
			adv(2)
			closed := false
			for i < n {
				if sql[i] == '*' && i+1 < n && sql[i+1] == '/' {
					adv(2)
					closed = true
					break
				}
				adv(1)
			}
			if !closed {
				return nil, &SyntaxError{Msg: "unterminated /* comment", Line: startLine, Col: startCol}
			}

		case c == '\'' || c == '"':
			quote := c
			start, startLine, startCol := i, line, col
			adv(1)
			closed := false
			for i < n {
				if sql[i] == '\\' && i+1 < n { // 反斜杠转义
					adv(2)
					continue
				}
				if sql[i] == quote {
					if i+1 < n && sql[i+1] == quote { // '' 双写转义
						adv(2)
						continue
					}
					adv(1)
					closed = true
					break
				}
				adv(1)
			}
			if !closed {
				return nil, &SyntaxError{Msg: "unterminated string literal", Line: startLine, Col: startCol}
			}
			toks = append(toks, Token{Kind: KindString, Text: sql[start:i], Pos: start, Line: startLine, Col: startCol})

		case c == '`':
			start, startLine, startCol := i, line, col
			adv(1)
			closed := false
			for i < n {
				if sql[i] == '`' {
					if i+1 < n && sql[i+1] == '`' { // `` 双写转义
						adv(2)
						continue
					}
					adv(1)
					closed = true
					break
				}
				adv(1)
			}
			if !closed {
				return nil, &SyntaxError{Msg: "unterminated backtick identifier", Line: startLine, Col: startCol}
			}
			toks = append(toks, Token{Kind: KindQuotedIdent, Text: sql[start:i], Pos: start, Line: startLine, Col: startCol})

		case isWordStart(c):
			start, startLine, startCol := i, line, col
			for i < n {
				if !isWordPart(sql[i]) {
					break
				}
				if sql[i] >= 0x80 {
					// 单词内部遇到 Unicode 空白（如全角空格）时结束当前单词。
					if r, _ := utf8.DecodeRuneInString(sql[i:]); r != utf8.RuneError && unicode.IsSpace(r) {
						break
					}
				}
				adv(1)
			}
			text := sql[start:i]
			if !utf8.ValidString(text) {
				return nil, &SyntaxError{Msg: "invalid UTF-8 in identifier", Line: startLine, Col: startCol}
			}
			toks = append(toks, Token{
				Kind: KindWord,
				Text: text,
				Word: strings.ToUpper(text),
				Pos:  start, Line: startLine, Col: startCol,
			})

		case isDigit(c):
			start, startLine, startCol := i, line, col
			for i < n && isNumberPart(sql[i]) {
				adv(1)
			}
			toks = append(toks, Token{Kind: KindNumber, Text: sql[start:i], Pos: start, Line: startLine, Col: startCol})

		case c == ';':
			toks = append(toks, Token{Kind: KindSemicolon, Text: ";", Pos: i, Line: line, Col: col})
			adv(1)

		default:
			// 单个字符的标点/运算符。
			toks = append(toks, Token{Kind: KindPunct, Text: string(c), Pos: i, Line: line, Col: col})
			adv(1)
		}
	}
	return toks, nil
}
