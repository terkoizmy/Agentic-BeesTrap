use crate::types::AppState;
use ratatui::widgets::TableState;

pub struct App {
    pub state: AppState,
    pub table_state: TableState,
}

impl App {
    pub fn new() -> Self {
        let app = Self {
            state: AppState::default(),
            table_state: TableState::default(),
        };
        // Verify state init
        app
    }

    pub fn next(&mut self) {
        let i = match self.table_state.selected() {
            Some(i) => {
                if i >= self.state.recent_transactions.len() - 1 {
                    0
                } else {
                    i + 1
                }
            }
            None => 0,
        };
        self.table_state.select(Some(i));
    }

    pub fn previous(&mut self) {
        let i = match self.table_state.selected() {
            Some(i) => {
                if i == 0 {
                    self.state.recent_transactions.len() - 1
                } else {
                    i - 1
                }
            }
            None => 0,
        };
        self.table_state.select(Some(i));
    }

    pub fn unselect(&mut self) {
        self.table_state.select(None);
    }

    pub fn select_index(&mut self, index: usize) {
        if index < self.state.recent_transactions.len() {
            self.table_state.select(Some(index));
        }
    }
}
