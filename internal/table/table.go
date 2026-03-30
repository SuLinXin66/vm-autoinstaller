package table

import (
	"regexp"
	"strings"

	"golang.org/x/text/width"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

type Table struct {
	headers []string
	rows    [][]string
}

func New(headers ...string) *Table {
	return &Table{headers: headers}
}

func (t *Table) AddRow(cols ...string) {
	t.rows = append(t.rows, cols)
}

func (t *Table) Render() string {
	ncols := len(t.headers)
	widths := make([]int, ncols)

	for i, h := range t.headers {
		w := displayWidth(h)
		if w > widths[i] {
			widths[i] = w
		}
	}
	for _, row := range t.rows {
		for i := 0; i < ncols && i < len(row); i++ {
			w := displayWidth(row[i])
			if w > widths[i] {
				widths[i] = w
			}
		}
	}

	var b strings.Builder
	writeBorder(&b, widths, "┌", "┬", "┐")
	writeRow(&b, widths, t.headers)
	writeBorder(&b, widths, "├", "┼", "┤")
	for _, row := range t.rows {
		padded := make([]string, ncols)
		copy(padded, row)
		writeRow(&b, widths, padded)
	}
	writeBorder(&b, widths, "└", "┴", "┘")

	return b.String()
}

func writeBorder(b *strings.Builder, widths []int, left, mid, right string) {
	b.WriteString(left)
	for i, w := range widths {
		b.WriteString(strings.Repeat("─", w+2))
		if i < len(widths)-1 {
			b.WriteString(mid)
		}
	}
	b.WriteString(right)
	b.WriteByte('\n')
}

func writeRow(b *strings.Builder, widths []int, cols []string) {
	b.WriteString("│")
	for i, w := range widths {
		val := ""
		if i < len(cols) {
			val = cols[i]
		}
		dw := displayWidth(val)
		pad := w - dw
		if pad < 0 {
			pad = 0
		}
		b.WriteByte(' ')
		b.WriteString(val)
		b.WriteString(strings.Repeat(" ", pad))
		b.WriteByte(' ')
		b.WriteString("│")
	}
	b.WriteByte('\n')
}

// displayWidth returns visual column width, ignoring ANSI escape codes
// and counting CJK wide characters as 2 columns.
func displayWidth(s string) int {
	clean := ansiRe.ReplaceAllString(s, "")
	w := 0
	for _, r := range clean {
		p := width.LookupRune(r)
		switch p.Kind() {
		case width.EastAsianWide, width.EastAsianFullwidth:
			w += 2
		default:
			w++
		}
	}
	return w
}
