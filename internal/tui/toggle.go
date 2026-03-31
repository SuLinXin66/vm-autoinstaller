package tui

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/gookit/color"
)

type ToggleItem struct {
	Name    string
	Label   string
	Checked bool
}

type ToggleResult struct {
	Items     []ToggleItem
	Cancelled bool
}

type toggleModel struct {
	items   []ToggleItem
	cursor  int
	done    bool
	cancel  bool
}

func (m toggleModel) Init() tea.Cmd { return nil }

func (m toggleModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			m.cancel = true
			m.done = true
			return m, tea.Quit
		case "enter":
			m.done = true
			return m, tea.Quit
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(m.items)-1 {
				m.cursor++
			}
		case " ":
			m.items[m.cursor].Checked = !m.items[m.cursor].Checked
		}
	}
	return m, nil
}

func (m toggleModel) View() string {
	if m.done {
		return ""
	}
	var b strings.Builder
	b.WriteString(color.Bold.Sprint("共享目录切换") + " (空格=切换 回车=确认 ESC=取消)\n\n")
	for i, item := range m.items {
		cursor := "  "
		if i == m.cursor {
			cursor = color.Cyan.Sprint("> ")
		}
		check := "[ ]"
		if item.Checked {
			check = color.Green.Sprint("[✓]")
		}
		label := item.Label
		if i == m.cursor {
			label = color.Bold.Sprint(label)
		}
		fmt.Fprintf(&b, "%s%s %s\n", cursor, check, label)
	}
	b.WriteString(color.Gray.Sprint("\n↑/↓ 移动  空格 切换  回车 确认  ESC 取消"))
	return b.String()
}

func RunToggle(items []ToggleItem) (ToggleResult, error) {
	m := toggleModel{items: items}
	p := tea.NewProgram(m)
	final, err := p.Run()
	if err != nil {
		return ToggleResult{Cancelled: true}, err
	}
	fm := final.(toggleModel)
	return ToggleResult{Items: fm.items, Cancelled: fm.cancel}, nil
}
