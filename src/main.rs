mod group_picker;
mod groups;
mod identity;
mod tmux;
mod ui;
mod working_status;

use std::{env, io};

fn main() -> io::Result<()> {
    let mut arguments = env::args_os().skip(1);
    let usage = || {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: omp-dock SOCKET SESSION",
        )
    };
    let socket = arguments.next().ok_or_else(usage)?;
    let session = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or_else(usage)?;
    let pane = env::var("TMUX_PANE").map_err(|_| usage())?;
    if arguments.next().is_some() {
        return Err(usage());
    }
    ui::run(&tmux::Server::new(socket, session, pane))
}
