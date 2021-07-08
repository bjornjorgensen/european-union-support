class TableBuilder
  # See README instructions to download this file.
  FORM_LABELS_CSV_PATH = File.join('source', 'Forms labels R2.09.csv')

  # Convert markers to badges.
  BADGES = {
    'issue' => 'Issue',
    'warning' => 'Attention',
    'proposal' => 'Proposal',
  }

  # Some XPath's are wider than the "Label and XPath" cell, so we break them across lines.
  LONG_XPATH_PREFIXES = [
    '/AWARD_CONTRACT/AWARDED_CONTRACT/CONTRACTORS/CONTRACTOR/',
    '/PROCEDURE/PT_AWARD_CONTRACT_WITHOUT_CALL/D_ACCORDANCE_ARTICLE/',
  ]

  def self.labels
    @labels ||= begin
      labels = {}

      # Ignore extra rows and columns.
      CSV.read(FORM_LABELS_CSV_PATH, headers: true).each do |row|
        if row.fields.any?
          labels[row.delete('Label')[1]] = row.delete_if{ |_, v| v.nil? }.to_h
        end
      end

      labels
    end
  end

  def initialize(language, extra_xpaths_to_list)
    @language = language
    @extra_xpaths_to_list = extra_xpaths_to_list
    @elem_targets = {}
    @enum_targets = {}
    @guidances = {}
    @output = ''
  end

  def add(text)
    @output << text
  end

  def to_s
    @output.chomp
  end

  def t(key)
    self.class.labels.fetch(key).fetch(@language)
  end

  # Helpers

  def heading(number, label)
    header 1, "#{number}: #{t(label)}"
  end

  def subheading(label)
    header 2, t(label)
  end

  def table(label=nil)
    start_table
    if label
      caption(t(label))
    end
    colgroup
    thead
    start_tbody
  end

  def row(label, help_labels: [], index: nil, xpath: nil, value: nil, reference: nil, guidance: false)
    if xpath
      if value
        @enum_targets[label] ||= [xpath, guidance]
      else
        @elem_targets[label] ||= [xpath, guidance]
      end
    end
    if xpath && guidance
      @guidances[xpath] ||= [label, guidance]
    end

    no_guidance = reference.nil? && (guidance == false || guidance == '')

    # Prepare "Label and XPath" content.
    if label
      content = t(label)
    else
      content = '<i>Unlabeled</i>'
    end
    help_labels.each do |help_label|
      content += " <i>(#{t(help_label)})</i>"
    end
    if xpath
      content += "<br>#{code(xpath)}"
    end
    @extra_xpaths_to_list.fetch(xpath, []).each do |extra|
      content += "<br>#{code(extra)}"
    end
    if value && !reference
      content += "is #{code(value)}"
    end

    # Prepare "Label and XPath" attributes.
    options = {}
    if no_guidance
      options[:colspan] = 2
    end
    if xpath
      options[:id] = xpath
    end

    start_row

    # "Index" cell.
    index_options = {}
    if index
      index_options[:id] = index
    end
    cell(index, index_options)

    # "Label and XPath" cell.
    start_cell(options)
    paragraph(content)
    end_cell

    # "OCDS guidance" cell.
    if reference
      if value
        target, text = @enum_targets.fetch(label)
      else
        target, text = @elem_targets.fetch(label)
      end
      if text.start_with?('/')
        text = @guidances.fetch(text)[1]
      end
      start_cell
      paragraph(link_to("Same as <i>#{t(label)}</i> above", "##{target}"))
      if !text.empty?
        markdown(text)
      end
      end_cell
    elsif !no_guidance
      if @guidances.key?(guidance)  # guidance is an xpath
        label_key, text = @guidances[guidance]
        if label_key
          infix = "<i>#{t(label_key)}</i>"
        else
          infix = "<code>#{guidance}</code>"
        end
        start_cell
        paragraph(link_to("Same as #{infix} above", "##{guidance}"))
        if !text.empty?
          markdown(text)
        end
        end_cell
      elsif guidance
        start_cell
        markdown(guidance)
        end_cell
      else
        start_cell
        paragraph('<i>Not yet mapped</i>')
        end_cell
      end
    end

    end_row
  end

  # HTML: Block

  def header(level, text)
    add <<-END
#{'#' * level} #{text}

END
  end

  # HTML: Table

  def start_table
    add <<-END
<div class="wy-table-responsive">
  <table class="docutils">
END
  end

  def end_table
    add <<-END
  </table>
</div>

END
  end

  def caption(text)
    add <<-END
    <caption>#{text}</caption>
END
  end

  def colgroup
    add <<-END
    <colgroup>
      <col width="8%">
      <col width="50%">
      <col width="42%">
    </colgroup>
END
  end

  def thead
    add <<-END
    <thead>
      <tr>
        <th>Index</th>
        <th>Label and XPath</th>
        <th>OCDS guidance</th>
      </tr>
    </thead>
END
  end

  def start_tbody
    add <<-END
    <tbody>
END
  end

  def end_tbody
    add <<-END
    </tbody>
END
  end

  def start_row
    add <<-END
      <tr>
END
  end

  def end_row
    add <<-END
      </tr>
END
  end

  def start_cell(attributes = {})
    if attributes.any?
      add <<-END
        <td #{attributes.map{ |k, v| %(#{k}="#{v}") }.join(' ')}>
END
    else
      add <<-END
        <td>
END
    end
  end

  def end_cell
    add <<-END
        </td>
END
  end

  def cell(text, attributes = {})
    if attributes.any?
      add <<-END
        <td #{attributes.map{ |k, v| %(#{k}="#{v}") }.join(' ')}>#{text}</td>
END
    else
      add <<-END
        <td>#{text}</td>
END
    end
  end

  def paragraph(text)
    add <<-END
          <p>#{text}</p>
END
  end

  def markdown(text)
    text = text.gsub('\n', "\n")
    BADGES.each do |key, label|
      text = text.gsub(/\(#{key.upcase}([^)#]+)?(?:#(\d+))?\)/) do
        prefixes = [%(<span class="badge badge-#{key}">)]
        suffixes = ['</span>']
        content = label.dup
        if $1
          content << $1.downcase
        end
        if $2
          prefixes << %(<a href="https://github.com/open-contracting-extensions/european-union/issues/#{$2}">)
          suffixes << '</a>'
          content << "##{$2}"
        end
        %(#{prefixes.join}#{content}#{suffixes.reverse.join})
      end
    end
    add Kramdown::Document.new(text, auto_ids: false).to_html
  end

  # HTML: Inline

  def link_to(text, target)
    %(<a href="#{target}">#{text}</a>)
  end

  def code(text)
    %(<code>#{text.sub(%r{\A(#{LONG_XPATH_PREFIXES.join('|')})}, '\1<wbr>')}</code>)
  end
end
