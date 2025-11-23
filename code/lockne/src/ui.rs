//! Simple TUI for monitoring Lockne activity

use crossterm::{
    event::{self, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Terminal,
};
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Stats shared between the TUI and the main program
#[derive(Clone, Default)]
pub struct Stats {
    pub packets_seen: u64,
    pub connections_tracked: u64,
    pub pids_seen: std::collections::HashSet<u32>,
    pub recent_logs: Vec<String>,
}

/// Shared statistics accessible from anywhere
pub type SharedStats = Arc<Mutex<Stats>>;

/// Run the TUI interface
pub async fn run_tui(stats: SharedStats) -> anyhow::Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Run the UI loop
    let result = ui_loop(&mut terminal, stats).await;

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    result
}

async fn ui_loop(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    stats: SharedStats,
) -> anyhow::Result<()> {
    loop {
        // Draw UI
        let stats_clone = stats.lock().unwrap().clone();
        terminal.draw(|f| {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(7),  // Stats box
                    Constraint::Min(0),     // Logs box
                ])
                .split(f.area());

            // Stats section
            let stats_text = vec![
                Line::from(vec![
                    Span::styled("Packets Seen: ", Style::default().fg(Color::Cyan)),
                    Span::raw(format!("{}", stats_clone.packets_seen)),
                ]),
                Line::from(vec![
                    Span::styled("Connections Tracked: ", Style::default().fg(Color::Cyan)),
                    Span::raw(format!("{}", stats_clone.connections_tracked)),
                ]),
                Line::from(vec![
                    Span::styled("Unique PIDs: ", Style::default().fg(Color::Cyan)),
                    Span::raw(format!("{}", stats_clone.pids_seen.len())),
                ]),
            ];

            let stats_widget = Paragraph::new(stats_text)
                .block(
                    Block::default()
                        .title(" Lockne Status ")
                        .borders(Borders::ALL)
                        .border_style(Style::default().fg(Color::Green)),
                );
            f.render_widget(stats_widget, chunks[0]);

            // Recent logs section
            let logs: Vec<ListItem> = stats_clone
                .recent_logs
                .iter()
                .rev()
                .take(chunks[1].height as usize - 2)
                .map(|log| {
                    ListItem::new(Line::from(log.clone()))
                })
                .collect();

            let logs_widget = List::new(logs)
                .block(
                    Block::default()
                        .title(" Recent Activity (press 'q' to quit) ")
                        .borders(Borders::ALL)
                        .border_style(Style::default().fg(Color::Yellow)),
                );
            f.render_widget(logs_widget, chunks[1]);
        })?;

        // Check for 'q' key to quit
        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                if key.code == KeyCode::Char('q') {
                    return Ok(());
                }
            }
        }
    }
}

/// Update stats from eBPF logs (called from logger)
pub fn update_stats_from_log(stats: &SharedStats, log_line: &str) {
    let mut stats = stats.lock().unwrap();
    
    // Count packets
    stats.packets_seen += 1;
    
    // Extract PID if present
    if let Some(pid_start) = log_line.find("pid=") {
        let pid_str = &log_line[pid_start + 4..];
        if let Some(pid_end) = pid_str.find(|c: char| !c.is_numeric()) {
            if let Ok(pid) = pid_str[..pid_end].parse::<u32>() {
                stats.pids_seen.insert(pid);
            }
        }
    }
    
    // Track new connections
    if log_line.contains("Tracked socket") {
        stats.connections_tracked += 1;
    }
    
    // Store recent logs (keep last 1000)
    stats.recent_logs.push(log_line.to_string());
    if stats.recent_logs.len() > 1000 {
        stats.recent_logs.remove(0);
    }
}
