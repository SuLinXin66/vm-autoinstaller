package table

const (
	Reset     = "\033[0m"
	Red       = "\033[31m"
	Green     = "\033[32m"
	Yellow    = "\033[33m"
	BrightRed = "\033[91m"
)

func Colorize(color, text string) string {
	if color == "" {
		return text
	}
	return color + text + Reset
}
