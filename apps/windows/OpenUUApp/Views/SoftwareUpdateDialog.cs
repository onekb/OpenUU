using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Shell;

namespace OpenUU.Views;

using OpenUU.Shared;

public sealed class SoftwareUpdateDialog : Window
{
    private readonly AppUpdater _updater;
    private readonly TextBlock _headingText;
    private readonly TextBlock _metaText;
    private readonly System.Windows.Controls.RichTextBox _notesViewer;
    private string _lastRenderedMarkdown = "\0";
    private readonly Border _progressCard;
    private readonly TextBlock _progressLabel;
    private readonly System.Windows.Controls.ProgressBar _progressBar;
    private readonly Border _errorCard;
    private readonly TextBlock _errorLabel;
    private readonly System.Windows.Controls.Button _skipBtn;
    private readonly System.Windows.Controls.Button _browserBtn;
    private readonly System.Windows.Controls.Button _primaryActionBtn;
    private readonly System.Windows.Controls.Button _closeBtn;
    private readonly System.Windows.Controls.Button _topCloseBtn;

    public SoftwareUpdateDialog(AppUpdater updater)
    {
        _updater = updater;
        Title = "OpenUU 版本更新";
        Width = 600;
        Height = 520;
        MinWidth = 520;
        MinHeight = 430;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBg");

        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            ResizeBorderThickness = new Thickness(0),
            GlassFrameThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            UseAeroCaptionButtons = false
        });

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int roundPref = Win32Interop.DWMWCP_ROUND;
            Win32Interop.DwmSetWindowAttribute(hwnd, Win32Interop.DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
        };

        var outerGrid = new Grid();
        outerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        outerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        outerGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Top Draggable Header
        var topHeader = new Grid
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(248, 250, 252))
        };
        topHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topHeader.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed && !_updater.IsInstalling)
            {
                try { DragMove(); } catch { }
            }
        };

        var headerRow = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            Margin = new Thickness(22, 15, 12, 14)
        };
        if (IconCompositor.BrandSquircleIcon != null)
        {
            headerRow.Children.Add(new System.Windows.Controls.Image
            {
                Source = IconCompositor.BrandSquircleIcon,
                Width = 40,
                Height = 40,
                Margin = new Thickness(0, 0, 12, 0)
            });
        }

        var titleCol = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _headingText = new TextBlock
        {
            FontSize = 16,
            FontWeight = FontWeights.Bold,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary")
        };
        _metaText = new TextBlock
        {
            FontSize = 11.5,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondary"),
            Margin = new Thickness(0, 3, 0, 0)
        };
        titleCol.Children.Add(_headingText);
        titleCol.Children.Add(_metaText);
        headerRow.Children.Add(titleCol);
        Grid.SetColumn(headerRow, 0);
        topHeader.Children.Add(headerRow);

        _topCloseBtn = new System.Windows.Controls.Button
        {
            VerticalAlignment = VerticalAlignment.Top,
            ToolTip = "关闭",
            Style = (Style)System.Windows.Application.Current.FindResource("WindowCloseBtnStyle")
        };
        var closeCanvas = new Canvas { Width = 10, Height = 10 };
        var closePath = new Path
        {
            Data = Geometry.Parse("M 0.5,0.5 L 9.5,9.5 M 9.5,0.5 L 0.5,9.5"),
            StrokeThickness = 1.3
        };
        closePath.SetBinding(Shape.StrokeProperty, new System.Windows.Data.Binding("Foreground")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(System.Windows.Controls.Button), 1)
        });
        closeCanvas.Children.Add(closePath);
        _topCloseBtn.Content = closeCanvas;
        _topCloseBtn.Click += (_, _) => { if (!_updater.IsInstalling) Close(); };
        Grid.SetColumn(_topCloseBtn, 1);
        topHeader.Children.Add(_topCloseBtn);

        Grid.SetRow(topHeader, 0);
        outerGrid.Children.Add(topHeader);

        var divider = new Border
        {
            Height = 1,
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("DividerBrush")
        };
        Grid.SetRow(divider, 1);
        outerGrid.Children.Add(divider);

        var root = new Grid { Margin = new Thickness(22, 16, 22, 20) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // 1. Subtitle
        var subLabel = new TextBlock
        {
            Text = "更新内容说明",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondary"),
            Margin = new Thickness(0, 0, 0, 6)
        };
        Grid.SetRow(subLabel, 0);
        root.Children.Add(subLabel);

        // 2. Release Notes Markdown Viewer
        _notesViewer = new System.Windows.Controls.RichTextBox
        {
            IsReadOnly = true,
            IsDocumentEnabled = true,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary"),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(6, 4, 6, 4)
        };
        var notesCard = new Border
        {
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("SubtleSurfaceBg"),
            BorderBrush = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(6),
            Child = _notesViewer
        };
        Grid.SetRow(notesCard, 1);
        root.Children.Add(notesCard);

        // 4. Live Progress / Error Banner
        var statusHost = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };

        _progressCard = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(239, 246, 255)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(147, 197, 253)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Visibility = Visibility.Collapsed
        };
        var progStack = new StackPanel();
        var progTop = new Grid();
        _progressLabel = new TextBlock
        {
            FontSize = 12,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary"),
            VerticalAlignment = VerticalAlignment.Center
        };
        var cancelDlBtn = new System.Windows.Controls.Button
        {
            Content = "取消下载",
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Padding = new Thickness(8, 2, 8, 2),
            FontSize = 11,
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        cancelDlBtn.Click += (_, _) => _updater.CancelDownload();
        progTop.Children.Add(_progressLabel);
        progTop.Children.Add(cancelDlBtn);
        _progressBar = new System.Windows.Controls.ProgressBar
        {
            Minimum = 0,
            Maximum = 100,
            Height = 6,
            Margin = new Thickness(0, 6, 0, 0)
        };
        progStack.Children.Add(progTop);
        progStack.Children.Add(_progressBar);
        _progressCard.Child = progStack;

        _errorCard = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(254, 242, 242)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(252, 165, 165)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Visibility = Visibility.Collapsed
        };
        _errorLabel = new TextBlock
        {
            FontSize = 11.5,
            Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(185, 28, 28)),
            TextWrapping = TextWrapping.Wrap
        };
        _errorCard.Child = _errorLabel;

        statusHost.Children.Add(_progressCard);
        statusHost.Children.Add(_errorCard);
        Grid.SetRow(statusHost, 2);
        root.Children.Add(statusHost);

        // 4. Action Buttons
        var footer = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        var leftBtns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        _skipBtn = new System.Windows.Controls.Button
        {
            Content = "忽略此版本",
            Padding = new Thickness(10, 6, 10, 6),
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        _skipBtn.Click += (_, _) =>
        {
            _updater.SkipCurrentAvailableVersion();
            Close();
        };

        var ghBtn = new System.Windows.Controls.Button
        {
            Content = "GitHub Releases",
            Padding = new Thickness(10, 6, 10, 6),
            FontSize = 12,
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        ghBtn.Click += (_, _) =>
        {
            string url = _updater.ReleaseInfo?.HtmlUrl ?? AppUpdater.GithubReleasesPage;
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        };
        leftBtns.Children.Add(_skipBtn);
        leftBtns.Children.Add(ghBtn);

        var rightBtns = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };
        _closeBtn = new System.Windows.Controls.Button
        {
            Content = "稍后",
            Padding = new Thickness(12, 6, 12, 6),
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        _closeBtn.Click += (_, _) => Close();

        _browserBtn = new System.Windows.Controls.Button
        {
            Content = "浏览器下载",
            Padding = new Thickness(12, 6, 12, 6),
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        _browserBtn.Click += (_, _) => _updater.OpenReleaseInBrowser();

        _primaryActionBtn = new System.Windows.Controls.Button
        {
            Content = "⬇ 一键下载并重启更新",
            Padding = new Thickness(14, 6, 14, 6),
            FontSize = 12.5,
            Style = (Style)System.Windows.Application.Current.FindResource("PrimaryButtonStyle")
        };
        _primaryActionBtn.Click += async (_, _) =>
        {
            if (_updater.HasAvailableUpdate)
                await _updater.PerformOneClickUpdateAsync();
            else
                await _updater.CheckForUpdatesAsync(manual: true);
        };

        rightBtns.Children.Add(_closeBtn);
        rightBtns.Children.Add(_browserBtn);
        rightBtns.Children.Add(_primaryActionBtn);

        footer.Children.Add(leftBtns);
        footer.Children.Add(rightBtns);
        Grid.SetRow(footer, 3);
        root.Children.Add(footer);

        Grid.SetRow(root, 2);
        outerGrid.Children.Add(root);

        Content = new Border
        {
            BorderBrush = (SolidColorBrush)System.Windows.Application.Current.FindResource("ControlBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBg"),
            ClipToBounds = true,
            Child = outerGrid
        };

        _updater.PropertyChanged += OnUpdaterPropertyChanged;
        Closed += (_, _) => _updater.PropertyChanged -= OnUpdaterPropertyChanged;
        SyncUi();
    }

    private void OnUpdaterPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        Dispatcher.BeginInvoke(SyncUi);
    }

    private void SyncUi()
    {
        var info = _updater.ReleaseInfo;
        bool hasUpdate = info?.HasUpdate == true;

        _headingText.Text = hasUpdate
            ? $"发现新版本 {info!.TagName}"
            : $"当前已是最新版本 ({AppVersion.Display})";

        var metaParts = new List<string> { $"当前版本：{AppVersion.Display}" };
        if (info != null)
        {
            if (!string.IsNullOrEmpty(info.FormattedDate))
                metaParts.Add($"发布日期：{info.FormattedDate}");
            if (!string.IsNullOrEmpty(info.FormattedSize))
                metaParts.Add($"安装包：{info.FormattedSize}");
        }
        _metaText.Text = string.Join("  ·  ", metaParts);

        string rawMd = !string.IsNullOrWhiteSpace(info?.ReleaseNotes)
            ? info!.ReleaseNotes
            : "暂无详细更新说明，可点击左下角前往 GitHub Releases 查看完整变更记录。";
        if (!string.Equals(rawMd, _lastRenderedMarkdown, StringComparison.Ordinal))
        {
            _lastRenderedMarkdown = rawMd;
            _notesViewer.Document = BuildMarkdownDocument(rawMd);
        }

        _progressCard.Visibility = _updater.IsInstalling ? Visibility.Visible : Visibility.Collapsed;
        _progressLabel.Text = _updater.InstallStatusText;
        _progressBar.Value = _updater.DownloadProgressPct;

        bool hasErr = !string.IsNullOrEmpty(_updater.InstallErrorText);
        _errorCard.Visibility = hasErr ? Visibility.Visible : Visibility.Collapsed;
        _errorLabel.Text = _updater.InstallErrorText;

        _skipBtn.Visibility = hasUpdate ? Visibility.Visible : Visibility.Collapsed;
        _browserBtn.Visibility = hasUpdate ? Visibility.Visible : Visibility.Collapsed;
        _closeBtn.Content = hasUpdate ? "稍后" : "关闭";

        bool busy = _updater.IsInstalling || _updater.IsChecking;
        _skipBtn.IsEnabled = !busy;
        _browserBtn.IsEnabled = !busy;
        _closeBtn.IsEnabled = !_updater.IsInstalling;
        _topCloseBtn.IsEnabled = !_updater.IsInstalling;
        _primaryActionBtn.IsEnabled = !busy;
        _primaryActionBtn.Content = hasUpdate
            ? (_updater.IsInstalling ? "正在更新..." : "⬇ 一键下载并重启更新")
            : (_updater.IsChecking ? "正在检查..." : "🔄 重新检查更新");
    }

    private static FlowDocument BuildMarkdownDocument(string markdown)
    {
        var textPrimary = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary");
        var textSecondary = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondary");
        var cardBorder = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBorder");
        var dividerBrush = (SolidColorBrush)System.Windows.Application.Current.FindResource("DividerBrush");
        var codeBg = new SolidColorBrush(System.Windows.Media.Color.FromArgb(22, 15, 23, 42));
        var quoteBar = new SolidColorBrush(System.Windows.Media.Color.FromRgb(14, 165, 233));

        var doc = new FlowDocument
        {
            PagePadding = new Thickness(6, 4, 6, 4),
            FontFamily = new System.Windows.Media.FontFamily("Microsoft YaHei UI, Segoe UI"),
            FontSize = 12.5,
            Foreground = textPrimary,
            LineHeight = 20
        };

        string[] lines = markdown.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        int i = 0;
        while (i < lines.Length)
        {
            string line = lines[i];
            string trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed))
            {
                i++;
                continue;
            }

            // 1. Fenced code block
            if (trimmed.StartsWith("```", StringComparison.Ordinal))
            {
                var codeLines = new List<string>();
                i++;
                while (i < lines.Length)
                {
                    if (lines[i].Trim().StartsWith("```", StringComparison.Ordinal))
                    {
                        i++;
                        break;
                    }
                    codeLines.Add(lines[i]);
                    i++;
                }
                var codePara = new Paragraph(new Run(string.Join("\n", codeLines)))
                {
                    FontFamily = new System.Windows.Media.FontFamily("Consolas, Microsoft YaHei UI"),
                    FontSize = 11.5,
                    Background = codeBg,
                    BorderBrush = cardBorder,
                    BorderThickness = new Thickness(1),
                    Padding = new Thickness(9, 7, 9, 7),
                    Margin = new Thickness(0, 4, 0, 6)
                };
                doc.Blocks.Add(codePara);
                continue;
            }

            // 2. Horizontal rule
            if ((trimmed.StartsWith("---", StringComparison.Ordinal) ||
                 trimmed.StartsWith("***", StringComparison.Ordinal) ||
                 trimmed.StartsWith("___", StringComparison.Ordinal)) &&
                trimmed.All(c => c is '-' or '*' or '_' or ' '))
            {
                doc.Blocks.Add(new BlockUIContainer(new Border
                {
                    Height = 1,
                    Background = dividerBrush,
                    Margin = new Thickness(0, 6, 0, 6)
                }));
                i++;
                continue;
            }

            // 3. Heading
            if (trimmed.StartsWith('#'))
            {
                int hashes = 0;
                while (hashes < trimmed.Length && trimmed[hashes] == '#') hashes++;
                if (hashes <= 6 && hashes < trimmed.Length && trimmed[hashes] == ' ')
                {
                    double sz = hashes switch { 1 => 16.0, 2 => 14.5, 3 => 13.5, _ => 12.8 };
                    var hp = new Paragraph
                    {
                        FontSize = sz,
                        FontWeight = FontWeights.Bold,
                        Margin = new Thickness(0, hashes <= 2 ? 8 : 5, 0, 4)
                    };
                    AppendInlineRuns(hp.Inlines, trimmed[(hashes + 1)..].Trim(), codeBg);
                    doc.Blocks.Add(hp);
                    if (hashes <= 2)
                    {
                        doc.Blocks.Add(new BlockUIContainer(new Border
                        {
                            Height = 1,
                            Background = dividerBrush,
                            Margin = new Thickness(0, 0, 0, 5)
                        }));
                    }
                    i++;
                    continue;
                }
            }

            // 4. Table
            if (trimmed.StartsWith('|') && i + 1 < lines.Length)
            {
                string sep = lines[i + 1].Trim();
                if (sep.StartsWith('|') && sep.Contains('-') && sep.All(c => "|:- \t".Contains(c)))
                {
                    var headers = ParseTableRow(trimmed);
                    var rows = new List<string[]>();
                    i += 2;
                    while (i < lines.Length && lines[i].Trim().StartsWith('|'))
                    {
                        rows.Add(ParseTableRow(lines[i].Trim()));
                        i++;
                    }
                    if (headers.Length > 0)
                    {
                        var tbl = new Table
                        {
                            CellSpacing = 0,
                            BorderBrush = cardBorder,
                            BorderThickness = new Thickness(1),
                            Margin = new Thickness(0, 4, 0, 6)
                        };
                        for (int c = 0; c < headers.Length; c++)
                            tbl.Columns.Add(new TableColumn());

                        var rg = new TableRowGroup();
                        var hr = new TableRow { Background = codeBg };
                        foreach (string h in headers)
                        {
                            var p = new Paragraph { Margin = new Thickness(0), FontWeight = FontWeights.SemiBold, FontSize = 11.5 };
                            AppendInlineRuns(p.Inlines, h, codeBg);
                            hr.Cells.Add(new TableCell(p)
                            {
                                Padding = new Thickness(7, 5, 7, 5),
                                BorderBrush = dividerBrush,
                                BorderThickness = new Thickness(0, 0, 0, 1)
                            });
                        }
                        rg.Rows.Add(hr);

                        foreach (var row in rows)
                        {
                            var tr = new TableRow();
                            for (int c = 0; c < headers.Length; c++)
                            {
                                string cellText = c < row.Length ? row[c] : "";
                                var p = new Paragraph { Margin = new Thickness(0), FontSize = 11.5 };
                                AppendInlineRuns(p.Inlines, cellText, codeBg);
                                tr.Cells.Add(new TableCell(p)
                                {
                                    Padding = new Thickness(7, 5, 7, 5),
                                    BorderBrush = dividerBrush,
                                    BorderThickness = new Thickness(0, 0, 0, 0.5)
                                });
                            }
                            rg.Rows.Add(tr);
                        }
                        tbl.RowGroups.Add(rg);
                        doc.Blocks.Add(tbl);
                        continue;
                    }
                }
            }

            // 5. Blockquote
            if (trimmed.StartsWith('>'))
            {
                var qLines = new List<string>();
                while (i < lines.Length && lines[i].Trim().StartsWith('>'))
                {
                    string q = lines[i].Trim()[1..].Trim();
                    if (!string.IsNullOrEmpty(q)) qLines.Add(q);
                    i++;
                }
                if (qLines.Count > 0)
                {
                    var qp = new Paragraph
                    {
                        Foreground = textSecondary,
                        Background = codeBg,
                        BorderBrush = quoteBar,
                        BorderThickness = new Thickness(3, 0, 0, 0),
                        Padding = new Thickness(9, 5, 9, 5),
                        Margin = new Thickness(0, 4, 0, 6),
                        FontSize = 12
                    };
                    AppendInlineRuns(qp.Inlines, string.Join("\n", qLines), codeBg);
                    doc.Blocks.Add(qp);
                }
                continue;
            }

            // 6. List item
            if (TryParseListLine(line, out int level, out string marker, out string itemBody))
            {
                var lp = new Paragraph
                {
                    Margin = new Thickness(14 + level * 16, 1.5, 0, 2.5),
                    TextIndent = -14
                };
                lp.Inlines.Add(new Run(marker + " ") { FontWeight = FontWeights.SemiBold, Foreground = textSecondary });
                AppendInlineRuns(lp.Inlines, itemBody, codeBg);
                doc.Blocks.Add(lp);
                i++;
                continue;
            }

            // 7. Paragraph
            var pLines = new List<string> { trimmed };
            i++;
            while (i < lines.Length)
            {
                string nl = lines[i];
                string nt = nl.Trim();
                if (string.IsNullOrEmpty(nt) || nt.StartsWith('#') || nt.StartsWith("```", StringComparison.Ordinal) ||
                    nt.StartsWith('>') || nt.StartsWith('|') || nt.StartsWith("---", StringComparison.Ordinal) ||
                    TryParseListLine(nl, out _, out _, out _))
                {
                    break;
                }
                pLines.Add(nt);
                i++;
            }
            var para = new Paragraph { Margin = new Thickness(0, 2, 0, 5) };
            AppendInlineRuns(para.Inlines, string.Join(" ", pLines), codeBg);
            doc.Blocks.Add(para);
        }

        return doc;
    }

    private static string[] ParseTableRow(string row)
    {
        string s = row.Trim();
        if (s.StartsWith('|')) s = s[1..];
        if (s.EndsWith('|')) s = s[..^1];
        return s.Split('|').Select(c => c.Trim()).ToArray();
    }

    private static bool TryParseListLine(string rawLine, out int level, out string marker, out string text)
    {
        int spaces = 0;
        foreach (char ch in rawLine)
        {
            if (ch == ' ') spaces += 1;
            else if (ch == '\t') spaces += 2;
            else break;
        }
        level = Math.Min(3, spaces / 2);
        string trimmed = rawLine.Trim();
        foreach (string p in new[] { "- ", "* ", "+ " })
        {
            if (trimmed.StartsWith(p, StringComparison.Ordinal))
            {
                marker = level == 0 ? "•" : (level == 1 ? "◦" : "▪");
                text = trimmed[p.Length..];
                return true;
            }
        }
        int d = 0;
        while (d < trimmed.Length && char.IsDigit(trimmed[d])) d++;
        if (d > 0 && trimmed[d..].StartsWith(". ", StringComparison.Ordinal))
        {
            marker = trimmed[..d] + ".";
            text = trimmed[(d + 2)..];
            return true;
        }
        marker = "";
        text = "";
        return false;
    }

    private static void AppendInlineRuns(InlineCollection inlines, string raw, System.Windows.Media.Brush codeBg)
    {
        int i = 0;
        var plain = new System.Text.StringBuilder();
        void FlushPlain()
        {
            if (plain.Length > 0)
            {
                inlines.Add(new Run(plain.ToString()));
                plain.Clear();
            }
        }

        while (i < raw.Length)
        {
            if (raw[i] == '`')
            {
                int end = raw.IndexOf('`', i + 1);
                if (end > i + 1)
                {
                    FlushPlain();
                    inlines.Add(new Run(" " + raw[(i + 1)..end] + " ")
                    {
                        FontFamily = new System.Windows.Media.FontFamily("Consolas, Microsoft YaHei UI"),
                        FontSize = 11.5,
                        Background = codeBg
                    });
                    i = end + 1;
                    continue;
                }
            }
            if (i + 1 < raw.Length && raw[i] == '*' && raw[i + 1] == '*')
            {
                int end = raw.IndexOf("**", i + 2, StringComparison.Ordinal);
                if (end > i + 2)
                {
                    FlushPlain();
                    var bold = new Bold();
                    AppendInlineRuns(bold.Inlines, raw[(i + 2)..end], codeBg);
                    inlines.Add(bold);
                    i = end + 2;
                    continue;
                }
            }
            if (raw[i] == '[')
            {
                int mid = raw.IndexOf("](", i + 1, StringComparison.Ordinal);
                int end = mid > i ? raw.IndexOf(')', mid + 2) : -1;
                if (mid > i && end > mid)
                {
                    FlushPlain();
                    string label = raw[(i + 1)..mid];
                    string url = raw[(mid + 2)..end];
                    if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
                    {
                        var link = new Hyperlink(new Run(label)) { NavigateUri = uri };
                        link.RequestNavigate += (_, e) =>
                        {
                            try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); } catch { }
                            e.Handled = true;
                        };
                        inlines.Add(link);
                    }
                    else
                    {
                        inlines.Add(new Run(label));
                    }
                    i = end + 1;
                    continue;
                }
            }
            if (raw[i] == '*' && (i + 1 >= raw.Length || raw[i + 1] != '*'))
            {
                int end = raw.IndexOf('*', i + 1);
                if (end > i + 1)
                {
                    FlushPlain();
                    inlines.Add(new Italic(new Run(raw[(i + 1)..end])));
                    i = end + 1;
                    continue;
                }
            }
            plain.Append(raw[i]);
            i++;
        }
        FlushPlain();
    }
}
