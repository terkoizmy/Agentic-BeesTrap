pub mod app;

use crate::types::UiMessage;
use app::App;
use chrono::Local;
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, MouseEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use eyre::Result;
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Cell, List, ListItem, Paragraph, Row, Sparkline, Table, Wrap},
    Frame, Terminal,
};
use std::{io, time::Duration};
use tokio::sync::mpsc::UnboundedReceiver;

pub async fn run_tui(
    mut rx: UnboundedReceiver<UiMessage>,
    confidence_threshold: f32,
) -> Result<()> {
    // Setup Terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Create App State
    let mut app = App::new();

    // Main Loop
    let tick_rate = Duration::from_millis(100);
    let mut last_tick = std::time::Instant::now();

    loop {
        terminal.draw(|f| ui(f, &mut app))?;

        // Handle Channel Messages (Non-blocking check)
        while let Ok(msg) = rx.try_recv() {
            match msg {
                UiMessage::NewTransaction(tx) => {
                    app.state.recent_transactions.insert(0, tx);
                    if app.state.recent_transactions.len() > 100 {
                        app.state.recent_transactions.pop();
                    }

                    // Fix: Keep selection consistent (don't jump to new tx at 0)
                    if let Some(selected) = app.table_state.selected() {
                        app.table_state.select(Some(selected + 1));
                    }
                }
                UiMessage::NewDetection(d) => {
                    app.state.recent_detections.insert(0, d);
                }
                UiMessage::NetworkUpdate(status) => {
                    app.state.network = status;
                }
                UiMessage::StatsUpdate(stats) => {
                    app.state.stats = stats;
                }
                UiMessage::ConfidenceUpdate(hash, c) => {
                    app.state.last_confidence = c;
                    // Find tx and update probability
                    // Note: We mutable iter meaning we can modify in place

                    if let Some((_idx, tx)) = app
                        .state
                        .recent_transactions
                        .iter_mut()
                        .enumerate()
                        .find(|(_, t)| t.hash == hash)
                    {
                        tx.probability = Some(c);
                        // Update suspicious status based on threshold
                        if c >= confidence_threshold {
                            tx.suspicious = true;
                            // Add to operation log
                            let log_msg = format!(
                                "{} [MATCH] Bot Detected: {} ({:.1}%)",
                                Local::now().format("%H:%M:%S"),
                                tx.short_hash,
                                c * 100.0
                            );
                            app.state.logs.push(log_msg);
                        } else {
                            tx.suspicious = false;
                            // Optional: Don't log safe ones to avoid clutter, user verified request.
                        }
                    }
                    // Re-do logic clean:
                }
                UiMessage::Log(msg) => {
                    app.state
                        .logs
                        .push(format!("{} {}", Local::now().format("%H:%M:%S"), msg));
                    if app.state.logs.len() > 50 {
                        app.state.logs.remove(0);
                    }
                }
                UiMessage::LatencyUpdate(l) => {
                    app.state.latency_ms = l;
                }
                UiMessage::ProcessingUpdate(_) => {
                    // TODO: Add logs handling for processing stages
                }
            }
        }

        // Handle Inputs
        let timeout = tick_rate
            .checked_sub(last_tick.elapsed())
            .unwrap_or_else(|| Duration::from_secs(0));

        if crossterm::event::poll(timeout)? {
            match event::read()? {
                Event::Key(key) => match key.code {
                    KeyCode::Char('q') => {
                        app.state.should_quit = true;
                    }
                    KeyCode::Down => app.next(),
                    KeyCode::Up => app.previous(),
                    KeyCode::Esc => app.unselect(),
                    KeyCode::Enter => {}
                    _ => {}
                },
                Event::Mouse(mouse) => {
                    if mouse.kind == MouseEventKind::Down(crossterm::event::MouseButton::Left) {
                        let (tx, ty, tw, th) = app.state.table_area;
                        let mx = mouse.column;
                        let my = mouse.row;

                        // Check if click is within table bounds
                        if mx >= tx && mx < tx + tw && my >= ty && my < ty + th {
                            // Calculate clicked row index
                            // Header is 1 line (height), border is 1 line.
                            // So row 0 starts at ty + 1 (border) + 1 (header) = ty + 2 ?
                            // Actually:
                            // The block has borders. inner area starts at +1.
                            // The table header is inside inner area.
                            // Table header height is 1. +1 margin. So first data row is at relative y=2 inside block?
                            // Wait, Block takes 2 (top+bottom). Inner area is relative to block.
                            // Header (1) + Margin (1) = 2.
                            // So Data starts at InnerY + 2.
                            // InnerY is BlockY + 1.
                            // So Data starts at BlockY + 1 + 2 = BlockY + 3.

                            let offset_y = my.saturating_sub(ty);

                            // If offset_y >= 3 (Top Border + Header + Margin)
                            if offset_y >= 3 {
                                let row_idx = (offset_y - 3) as usize + app.table_state.offset();
                                if row_idx < app.state.recent_transactions.len() {
                                    app.table_state.select(Some(row_idx));
                                }
                            }
                        }

                        // Check if click is within AI Insight bounds (Removed browser open)
                        // let (ax, ay, aw, ah) = app.state.ai_insight_area;
                        // if mx >= ax && mx < ax + aw && my >= ay && my < ay + ah { ... }

                        // Check if click is within Logs bounds (Removed browser open)
                        // let (lx, ly, lw, lh) = app.state.logs_area;
                        // if mx >= lx && mx < lx + lw && my >= ly && my < ly + lh { ... }
                    }
                }
                _ => {}
            }
        }

        if last_tick.elapsed() >= tick_rate {
            last_tick = std::time::Instant::now();
        }

        if app.state.should_quit {
            break;
        }
    }

    // Restore Terminal
    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    terminal.show_cursor()?;

    Ok(())
}

fn ui(f: &mut Frame, app: &mut App) {
    // 1. Layouts
    //     .split(f.area()); // Fixed deprecated size()
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(0),
            Constraint::Length(12),
        ])
        .split(f.area());

    let header_area = chunks[0];
    let main_area = chunks[1];
    let bottom_area = chunks[2];

    let main_chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(main_area);

    let left_panel = main_chunks[0]; // Tx Table
    let right_panel = main_chunks[1]; // AI Insight

    let bottom_chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(bottom_area);

    let stats_panel = bottom_chunks[0]; // Economic Impact
    let logs_panel = bottom_chunks[1]; // System Logs

    // 2. Header
    render_header(f, app, header_area);

    // 3. Tx Table (Left)
    render_tx_table(f, app, left_panel);

    // 4. AI Insight (Right)
    render_ai_insight(f, app, right_panel);

    // 5. Economic Impact (Bottom Left)
    render_economic_impact(f, app, stats_panel);

    // 6. Logs (Bottom Right)
    app.state.logs_area = (
        logs_panel.x,
        logs_panel.y,
        logs_panel.width,
        logs_panel.height,
    );
    let logs: Vec<ListItem> = app
        .state
        .logs
        .iter()
        .rev() // Show newest at top? Or render normally and auto-scroll? Usually logs are new at bottom.
        // If we use List, we can reverse to show newest at top if we want.
        // Let's show newest at top for visibility.
        .map(|m| {
            let content = Line::from(Span::raw(m));
            ListItem::new(content)
        })
        .collect();

    // 6. Logs (Bottom Right)
    app.state.logs_area = (
        logs_panel.x,
        logs_panel.y,
        logs_panel.width,
        logs_panel.height,
    );

    let logs_list = List::new(logs).block(
        Block::default()
            .borders(Borders::ALL)
            .title("Operation Logs"),
    );
    f.render_widget(logs_list, logs_panel);

    // 7. Status Message Overlay (Centered at bottom of header or top of main)
    if let Some((msg, time)) = &app.state.status_message {
        if time.elapsed() < std::time::Duration::from_secs(3) {
            let area = centered_rect(60, 3, f.area());
            let block = Block::default()
                .borders(Borders::ALL)
                .style(Style::default().bg(Color::Blue).fg(Color::White));
            let p = Paragraph::new(msg.clone())
                .block(block)
                .alignment(ratatui::layout::Alignment::Center);
            f.render_widget(p, area);
        }
    }
}

// Helper for centering
fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}

fn render_header(f: &mut Frame, app: &App, area: Rect) {
    let status_color = if app.state.network.connected {
        Color::Green
    } else {
        Color::Red
    };
    let status_text = if app.state.network.connected {
        "ONLINE"
    } else {
        "OFFLINE"
    };

    let time = Local::now().format("%H:%M:%S").to_string();

    let header_text = vec![
        Span::styled(
            "BeesTrap - MAV DEFENSE AGENT",
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" | "),
        Span::styled(
            format!("WSS Ethereum: {}", status_text),
            Style::default().fg(status_color),
        ),
        Span::raw(" | "),
        Span::styled(
            format!("Block: #{}", app.state.network.block_number),
            Style::default().fg(Color::Yellow),
        ),
        Span::raw(" | "),
        Span::raw(time),
    ];

    let p = Paragraph::new(Line::from(header_text))
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(Color::Cyan)),
        )
        .alignment(ratatui::layout::Alignment::Center);

    f.render_widget(p, area);
}

fn render_tx_table(f: &mut Frame, app: &mut App, area: Rect) {
    // Store area for click detection
    app.state.table_area = (area.x, area.y, area.width, area.height);

    let header_cells = ["Time", "Hash", "Value", "Gas", "Status"]
        .iter()
        .map(|h| Cell::from(*h).style(Style::default().fg(Color::Yellow)));
    let header = Row::new(header_cells).height(1).bottom_margin(1);

    let rows = app.state.recent_transactions.iter().map(|tx| {
        let status_text = if let Some(prob) = tx.probability {
            if prob >= 0.0 {
                // Just checked it exists
                if tx.suspicious {
                    "MEV DETECTED"
                } else {
                    "SAFE"
                }
            } else {
                "Pending"
            }
        } else {
            "Pending"
        };

        let status_color = if let Some(_) = tx.probability {
            if tx.suspicious {
                Color::Red
            } else {
                Color::Green
            }
        } else {
            Color::White
        };

        let cells = vec![
            Cell::from("00:00:00"), // TODO: Proper Time
            Cell::from(tx.short_hash.clone()),
            Cell::from(format!("{:.4} E", tx.value_eth)),
            Cell::from(format!("{:.0}", tx.gas_gwei)),
            Cell::from(status_text).style(Style::default().fg(status_color)),
        ];
        Row::new(cells)
            .height(1)
            .style(Style::default().fg(Color::Gray))
    });

    let t = Table::new(
        rows,
        [
            Constraint::Length(10),
            Constraint::Length(12),
            Constraint::Length(10),
            Constraint::Length(8),
            Constraint::Min(10),
        ],
    )
    .header(header)
    .block(
        Block::default()
            .borders(Borders::ALL)
            .title("Live Mempool Activity"),
    )
    .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED))
    .highlight_symbol(">> ");

    f.render_stateful_widget(t, area, &mut app.table_state);
}

fn render_ai_insight(f: &mut Frame, app: &mut App, area: Rect) {
    app.state.ai_insight_area = (area.x, area.y, area.width, area.height);

    let block = Block::default()
        .title("AI Deep Insight")
        .borders(Borders::ALL);
    f.render_widget(block, area);

    // Check selection
    if let Some(selected_idx) = app.table_state.selected() {
        if let Some(tx) = app.state.recent_transactions.get(selected_idx) {
            let inner_area = area.inner(ratatui::layout::Margin {
                vertical: 1,
                horizontal: 1,
            });

            // Just basic visualization string for now or simulated BarChart
            // Real features are in FeatureVector but TransactionSummary doesn't have them all...
            // Uh oh, TransactionSummary only has visual info.
            // For now, let's just show what we have in summary + Mock confidence

            let text = vec![
                Line::from(vec![
                    Span::raw("Hash: "),
                    Span::styled(&tx.hash, Style::default().fg(Color::White)),
                ]),
                Line::from(vec![
                    Span::raw("Value: "),
                    Span::styled(
                        format!("{:.4} ETH", tx.value_eth),
                        Style::default().fg(Color::Cyan),
                    ),
                ]),
                Line::from(vec![
                    Span::raw("Gas Price: "),
                    Span::styled(
                        format!("{:.2} Gwei", tx.gas_gwei),
                        Style::default().fg(Color::Cyan),
                    ),
                ]),
                Line::from(""),
                Line::from(vec![
                    Span::raw("Predator Probability: "),
                    Span::styled(
                        if let Some(prob) = tx.probability {
                            format!("{:.1}%", prob * 100.0)
                        } else {
                            "Processing...".to_string()
                        },
                        Style::default()
                            .fg(if tx.suspicious {
                                Color::Red
                            } else if tx.probability.is_some() {
                                Color::Green
                            } else {
                                Color::White
                            })
                            .add_modifier(Modifier::BOLD),
                    ),
                ]),
                Line::from(""),
                Line::from(vec![
                    Span::raw("Etherscan Link: "),
                    Span::styled(
                        format!("https://etherscan.io/tx/{}", tx.hash),
                        Style::default().fg(Color::Blue),
                    ),
                ]),
            ];

            let p = Paragraph::new(text).wrap(Wrap { trim: true });
            f.render_widget(p, inner_area);
        }
    } else {
        let p = Paragraph::new("Select a transaction to view AI analysis")
            .alignment(ratatui::layout::Alignment::Center);
        f.render_widget(
            p,
            area.inner(ratatui::layout::Margin {
                vertical: 4,
                horizontal: 1,
            }),
        );
    }
}

fn render_economic_impact(f: &mut Frame, app: &App, area: Rect) {
    let inner_area = area.inner(ratatui::layout::Margin {
        vertical: 1,
        horizontal: 1,
    });

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(4), Constraint::Min(0)])
        .split(inner_area);

    // Metrics
    let eth_saved = app.state.stats.eth_saved;
    let gas_saved = app.state.stats.gas_saved;
    let efficiency = app.state.stats.efficiency_boost;

    let stats_text = vec![
        Line::from(vec![
            Span::raw("ETH Saved: "),
            Span::styled(
                format!("Ξ {:.4}", eth_saved),
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(vec![
            Span::raw("Gas Prevented: "),
            Span::styled(
                format!("{} Gwei", gas_saved),
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(vec![
            Span::raw("Efficiency Boost: "),
            Span::styled(
                format!("+{:.2}%", efficiency),
                Style::default().fg(Color::Green),
            ),
        ]),
    ];

    let p = Paragraph::new(stats_text);
    f.render_widget(p, chunks[0]);

    // Sparkline
    // Need u64 data. AppState has history_saved (Vec<u64>)
    // Sparkline works with &[u64]
    let data = &app.state.stats.history_saved;
    // Convert to u64 if needed, usually they are u64.

    let sparkline = Sparkline::default()
        .block(Block::default().title("Funds Saved Over Time"))
        .data(data)
        .style(Style::default().fg(Color::Green));
    f.render_widget(sparkline, chunks[1]);

    f.render_widget(
        Block::default()
            .title("VANGUARD ECONOMIC IMPACT")
            .borders(Borders::ALL)
            .border_style(Style::default().fg(Color::Yellow)),
        area,
    );
}
