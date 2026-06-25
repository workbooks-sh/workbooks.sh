// §8 ratatui — the full TUI framework (over crossterm). Blocked on §7 unix std.
// Runtime side proven by unix_termios.c (§4 tty). Builds a Terminal over the crossterm
// backend, renders one frame with a bordered widget into the virtual tty, exits 42. Once
// crossterm's unix backend compiles, ratatui rides §4 tty with no new host import.
use ratatui::backend::CrosstermBackend;
use ratatui::widgets::{Block, Borders, Paragraph};
use ratatui::Terminal;
use std::io::stdout;

fn main() {
    let backend = CrosstermBackend::new(stdout());
    let mut terminal = Terminal::new(backend).unwrap();
    let res = terminal.draw(|f| {
        let widget = Paragraph::new("washy").block(Block::default().borders(Borders::ALL));
        f.render_widget(widget, f.area());
    });
    std::process::exit(if res.is_ok() { 42 } else { 1 });
}
