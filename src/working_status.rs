// The command prints a tab before each pane ID. Terminal tab stops capture as spaces.
pub(crate) const PANE_HEADER: &str = "\t#{pane_id}";

pub(crate) fn messages(batch: &str) -> impl Iterator<Item = (&str, &str)> {
    batch.split('\t').skip(1).filter_map(|record| {
        let (pane, screen) = record.split_once('\n')?;
        let mut rows = screen.lines().rev();
        rows.find(|line| running_footer(line))?;
        let label = rows.next()?.trim_start().strip_prefix("⎋ ")?.trim_end();
        let rate = label
            .split_once(" tok/s")
            .and_then(|(meter, _)| meter.rsplit_once("  "))
            .filter(|(_, trailer)| {
                trailer
                    .split_once(' ')
                    .is_some_and(|(_, number)| number.parse::<f32>().is_ok_and(f32::is_finite))
            });
        let label = rate.map_or(label, |(body, _)| body.trim_end());
        (!label.is_empty()).then_some((pane, label))
    })
}

pub(crate) fn spinner(marker: &str) -> bool {
    matches!(
        marker,
        "⠋" | "⠙" | "⠹" | "⠸" | "⠼" | "⠴" | "⠦" | "⠧" | "⠇" | "⠏"
    )
}

fn running_footer(line: &str) -> bool {
    let Some((brand, rest)) = line.trim_start().split_once(' ') else {
        return false;
    };
    let Some((elapsed, model)) = rest.split_once(" > ") else {
        return false;
    };
    let marker = brand.split_once('-').map_or(brand, |(glyph, _)| glyph);
    let Some(number) = elapsed.strip_suffix(['s', 'm', 'h']) else {
        return false;
    };
    spinner(marker)
        && !number.is_empty()
        && number.bytes().all(|byte| byte.is_ascii_digit())
        && (model.starts_with("◉ ") || model.contains(" > 📁 "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_spaces_are_content_even_with_a_throughput_trailer() {
        let screen = concat!(
            "\t%2\n ⎋ Measuring  LC peaks     ⚡ 24.1 tok/s\n",
            " ⠏ 3s > ◉ GPT > 📁 ~/lab\n",
            "\t%3\n  ⎋ Reviewing  two spectra\n",
            " ⠙ 2s > ◉ GPT > 📁 ~/lab\n",
        );
        assert_eq!(
            messages(screen).collect::<Vec<_>>(),
            [
                ("%2", "Measuring  LC peaks"),
                ("%3", "Reviewing  two spectra")
            ]
        );
    }

    #[test]
    fn missing_loader_at_current_footer_does_not_reuse_earlier_messages() {
        let screen = concat!(
            "\t%1\n  ⎋ Earlier sample printed by a command\n",
            " ⠼ 15s > ◉ GPT-6.2 Astra > 📁 ~/lab\n",
            "Last conversation line\n ⠋-lab 1m > ◉ GPT-6.2 Astra > 📁 ~/lab\n",
        );
        assert!(messages(screen).next().is_none());
    }

    #[test]
    fn messages_belong_to_the_pane_with_the_running_composer() {
        let batch = concat!(
            "\t%5\n  ⎋ Locating OMP session progress and published messages     ⚡ 24.1 tok/s\n",
            " ⠏ 14m > ◉ GPT-6.2 Astra > 📁 ~/lab\n╰─\n",
            "\t%17\n  ⎋ An earlier message\nordinary output\n",
            " ⠙ 2s > ◉ GPT-6.2 Astra > 📁 ~/lab\n",
            "\t%18\n  ⎋ Unrelated text\n ⠏ an example > in chat\n",
            "\t%20\nlast Telegram summary\n ⠏ 4m > ◉ GPT-6.2 Astra > 📁 ~/lab\n",
        );
        assert_eq!(
            messages(batch).collect::<Vec<_>>(),
            [("%5", "Locating OMP session progress and published messages")]
        );
    }
}
