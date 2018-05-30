class XmlParser
  # @return [String] the file's basename without extension
  attr_reader :basename
  # @return [Nokogiri::XML::Node] the XML schema
  attr_reader :schema
  # @return [Array<TreeNode>] the built tree
  attr_reader :tree

  class << self
    attr_reader :xml
  end

  @xml = {}

  # @param [String] path the path to the XSD file
  def initialize(path, follow=true)
    @basename = File.basename(path, '.xsd')
    @schemas = import(path).values
    @schema = @schemas[0]
    @follow = follow

    @tree = []
  end

  # Finds the `schema` tag of the XML document at the given path, and then recursively finds the `schema` tags of the
  # XML documents referenced by `include` or `import` tags.
  #
  # @return [Hash] the key is a file path and the value is the `schema` tag of an XML document
  def import(path)
    schemas = {}
    directory = File.dirname(path)
    schemas[path] = parse(path)
    schemas[path].xpath('./xs:include|./xs:import').each do |n| # discard import's namespace
      schemas.merge!(import(File.join(directory, n['schemaLocation'])))
    end
    schemas
  end

  # @return [Nokogiri::XML::Node] the `schema` tag of the XML document at the given path
  def parse(path)
    # Assume the XML declaration, xs:schema attributes, and comments are irrelevant.
    self.class.xml[path] ||= node_set(Nokogiri::XML(File.read(path)).xpath('/xs:schema'), size: 1, names: ['schema'], required: ['elementFormDefault', 'attributeFormDefault', 'version'], optional: ['targetNamespace'], children: true)[0]
  end

  # Prints the built tree as a CSV to standard output.
  def to_csv
    FileUtils.mkdir_p('out')
    CSV.open(File.join('out', "#{@basename}.csv"), 'w') do |csv|
      csv << %w(form index) + PROPERTIES
      tree.each do |node|
        if node.attributes.key?(:enumeration)
          node.attributes[:enumeration] = node.attributes[:enumeration].join('|')
        end

        csv << [@basename, node.attributes.values_at(*LOCATORS).compact.join('.')] + node.attributes.values_at(*PROPERTIES)
      end
    end
  end

  # @param condition
  # @param [String] message
  # @param [Nokogiri::XML::Node] node a node
  # @raise if the condition isn't met
  def assert(condition, message='', node=nil)
    unless condition
      message = "#{@basename}: #{message}"
      if node
        message += " at #{node.path}: #{node.to_s[0..2000]}"
      end
      raise message
    end
  end

  # @raise if the actual value isn't the expected value
  def assert_equal(actual, expected, message='', node=nil)
    assert actual == expected, "expected #{expected}, got #{actual} #{message}", node
  end

  # @raise if the first value is not included in the second value
  def assert_in(first, second, message='', node=nil)
    assert Array === second && second.include?(first), "expected #{second} to include '#{first}' #{message}", node
  end

  # @param [Nokogiri::XML::Node] node a node
  # @raise if the node has children
  def assert_leaf(node)
    assert node.element_children.empty?, 'expected no children', node
  end

  # Checks whether a node set meets expectations.
  #
  # `:size` and `:xml` are always tested. If `:name_only` is set, attributes and children are not tested. If `:index`
  # is set, only the node at that index is tested. Otherwise, all options and all nodes are tested.
  #
  # @param [Nokogiri::XML::NodeSet] ns a node set
  # @param [Hash] opts
  # @option opts [Integer, Range] :size The expected number of nodes in the node set.
  # @option opts [Hash] :xml A hash of array indices/slices to XML strings.
  # @option opts [Boolean] :name_only Only test `:size`, `:xml` and `:names`.
  # @option opts [Integer] :index The index of the single node to test.
  # @option opts [String] :names The allowed tag names.
  # @option opts [Array<String>] :attributes The expected attribute names. `[]` by default.
  # @option opts [Array<String>] :required The names of required attributes.
  # @option opts [Array<String>] :optional The names of optional attributes.
  # @option opts [Array<String>] :disjoint The names of disjoint required attributes.
  # @option opts [String, true] :children The nodes are expected to have:
  #   * If `"any"`, anything
  #   * If `true`: children
  #   * If `"text"`: no tag children
  #   * If omitted: no children
  # @return the node set
  def node_set(ns, opts)
    # Check options.
    if opts.key?(:attributes) && (opts.key?(:required) || opts.key?(:optional))
      raise 'must not set both :attributes and any of :required, :optional'
    end
    if opts.key?(:size) && (Range === opts[:size] && opts[:size].last > 1 || Integer === opts[:size] && opts[:size] > 1) && opts.key?(:index) && !opts.key?(:xml)
      raise 'must set :xml if the maximum :size is greater than 1 and :index is set'
    end

    assert opts.fetch(:size) === ns.size, "expected #{opts[:size]}, got #{ns.size} elements: #{ns}"

    if opts[:xml]
      opts[:xml].each do |k, v|
        assert_equal ns[k].to_xml, v
      end
    end

    if opts.key?(:index)
      node(ns[opts[:index]], opts)
    else
      ns.each do |n|
        node(n, opts)
      end
    end

    ns
  end

  # Checks whether a node meets expectations.
  #
  # @param [Nokogiri::XML::Node] n
  # @param [Hash] opts
  # @see node_set
  def node(n, opts)
    assert_in n.name, opts.fetch(:names), 'tag name', n

    if !opts[:name_only]
      if opts.key?(:required) || opts.key?(:optional)
        allowed_attributes(n, opts.slice(:required, :optional))
      else
        allowed_attributes(n, required: opts.fetch(:attributes, []))
      end
    end

    if !opts[:name_only]
      assert !opts.key?(:children) && n.children.none? ||
        opts[:children] == 'text' && n.element_children.none? ||
        opts[:children] == true && n.children.any? ||
        opts[:children] == 'any', "expected #{opts[:children].inspect} children", n
    end
  end

  # Checks whether required attributes are present on a node and whether any attributes are unexpected.
  #
  # @param [Nokogiri::XML::Node] n
  # @param [Hash] opts
  def allowed_attributes(n, opts={})
    required = opts.fetch(:required, [])
    required.each do |attribute|
      assert_in attribute, n.attributes.keys, 'required attribute name', n
    end

    disjoint = opts.fetch(:disjoint, [])
    assert disjoint.empty? || disjoint.one?{ |attribute| n.attributes.keys.include?(attribute) }, "expected one of #{disjoint.join(', ')}", n

    unexpected = n.attributes.keys - required - disjoint - opts.fetch(:optional, [])
    assert unexpected.empty?, "unexpected attributes #{unexpected}", n
  end

  # Checks the form's schema and then the TED schemas for the given path.
  #
  # @param [String] path an XPath
  # @return [Nokogiri::XML::NodeSet] a nodeset
  def xpath(path)
    @schemas.each do |s|
      node_set = s.xpath(path)
      if !node_set.empty?
        return node_set
      elsif !@follow
        return
      end
    end
    nil
  end

  # @return [Symbol] the symbol for the locator at this depth
  # @raise if the depth of the locator is unexpected
  def key_for_depth(depth)
    key = "index#{depth + 1}".to_sym
    if !LOCATORS.include?(key)
      raise "missing property #{key}"
    end
    key
  end

  # @param [Nokogiri::XML::Node] node a node
  # @param [Hash] attributes
  def set_last(node, attributes)
    attributes.each do |key, value|
      assert !tree.last.attributes.key?(key), "unexpected #{key} (was #{tree.last.attributes[key]})", node
      tree.last.attributes[key] = value
    end
  end

  # Adds or merges entries to the tree.
  def enter(n, depth, opts)
    opts.delete(:enter)
    if opts[:reference] && opts[:reference] == n['name']
      tree.last.merge(n, opts, %i(reference))
    elsif n.name == 'attribute' && n['name'] == 'CTYPE'
      tree.last.merge(n, opts, %i(reference name) + [key_for_depth(depth)])
    else
      tree << TreeNode.new(n, opts)
    end
  end

  # Annotates an entry in the built tree.
  #
  # @param [Nokogiri::XML::Node] node a node
  # @param [Array<String>] annotations the node's allowed annotation elements
  def annotate(node, annotations)
    node = node.dup
    annotations.each do |name|
      n = node.element_children.find{ |child| child.name == name }
      if n
        case n.name
        when 'annotation'
          allowed_attributes(n)
          ns = node_set(n.element_children, size: 1, names: ['documentation'], optional: ['lang'], children: 'any') # discard `lang`
          set_last(node, annotation: ns[0].text.split("\n").map(&:strip).join("\n").strip)
          # TODO after other `base` followed
          # if ns[0].text != ns[0].text.split("\n").map(&:strip).join("\n").strip
          #   $stderr.puts ns[0]
          #   $stderr.puts ns[0].text.split("\n").map(&:strip).join("\n").strip
          # end
        when 'unique'
          allowed_attributes(n, required: ['name'])
          ns = node_set(n.element_children, size: 2, index: 1, names: ['field'], attributes: ['xpath'], xml: {0 => '<xs:selector xpath="*"/>'})
          set_last(node, unique: ns[1]['xpath'])
        else
          assert false, "unexpected #{n.name}", n
        end
        n.unlink
      end
    end
    node
  end

  # Follows a `ref` or `type` attribute.
  def follow(n, depth, opts, optional=false)
    matches = [n.key?('type'), n.key?('ref'), n.element_children.any?].select(&:itself)
    assert matches.one? || optional && matches.none?, 'expected one of "type", "ref" or children', n

    set = nil

    if n.key?('type')
      if !NO_FOLLOW.include?(n['type'])
        set = xpath(%w(complex simple).map{ |prefix| "./xs:#{prefix}Type[@name='#{n['type']}']" }.join('|'))
        names = %w(complexType simpleType)
      end
    elsif n.key?('ref')
      if !NO_FOLLOW.include?(n['ref'])
        set = xpath("./xs:#{n.name}[@name='#{n['ref'].split(':', 2).last}']") # remove namespace
        names = [n.name]
      end
    end

    if set
      ns = node_set(set, size: 1, names: names, name_only: true)
      elements(ns[0], depth, opts)
    end
  end

  # Builds the tree by traversing the XML from the given node.
  #
  # @param [Nokogiri::XML::Node] n a node
  # @param [Integer] depth the depth of the node
  # @param [Hash] opts
  # @option opts :index0
  # @option opts :index1
  # @option opts :index2
  # @option opts :index3
  # @option opts :index4
  # @option opts :index5
  # @option opts :ref
  def elements(n, depth, opts)
    case n.name
    when 'sequence'
      allowed_attributes(n)
      n = annotate(n, ['annotation'])
      ns = node_set(n.element_children, size: 1..16, names: %w(choice element group sequence), name_only: true)
      ns.to_enum.with_index(1) do |c, i|
        elements(c, depth + 1, opts.merge(key_for_depth(depth) => i))
      end

    when 'choice'
      allowed_attributes(n, optional: ['maxOccurs']) # TODO preserve maxOccurs
      n = annotate(n, ['annotation'])
      ns = node_set(n.element_children, size: 1..6, names: %w(choice element group sequence), name_only: true)
      ns.to_enum.with_index(97) do |c, i|
        elements(c, depth + 1, opts.merge(key_for_depth(depth) => i.chr))
      end

    when 'element'
      enter(n, depth, opts)

      allowed_attributes(n, disjoint: %w(name ref), optional: %w(type minOccurs maxOccurs))
      n = annotate(n, %w(annotation unique))
      ns = node_set(n.element_children, size: 0..1, names: %w(complexType simpleType), name_only: true)
      ns.each do |c|
        elements(c, depth, opts)
      end

      follow(n, depth, opts.merge(reference: n['ref'] || n['type']))

    when 'group'
      enter(n, depth, opts)

      allowed_attributes(n, disjoint: %w(name ref), optional: %w(minOccurs maxOccurs))
      n = annotate(n, ['annotation'])
      ns = node_set(n.element_children, size: 0..1, names: %w(choice sequence), children: true)
      ns.each do |c|
        elements(c, depth, opts)
      end

      follow(n, depth, opts.merge(reference: n['ref']))

    when 'complexType'
      if opts[:enter]
        enter(n, depth, opts)
      end

      allowed_attributes(n, optional: %w(name mixed)) # discard mixed TODO preserve name
      n = annotate(n, ['annotation'])
      ns = node_set(n.element_children, size: 0..2, names: %w(attribute choice group sequence complexContent simpleContent), name_only: true)
      ns.each do |c|
        elements(c, depth, opts)
      end

    when 'simpleType'
      if opts[:enter]
        enter(n, depth, opts)
      end

      allowed_attributes(n, optional: ['name']) # TODO preserve name
      n = annotate(n, ['annotation'])
      ns = node_set(n.element_children, size: 1, names: ['restriction'], attributes: ['base'], children: 'any')

      base = ns[0]['base']
      # TODO follow/set `base` reference

      ns = node_set(ns[0].element_children, size: 0..9999, names: RESTRICTIONS.map(&:to_s), attributes: ['value'])

      if ns.any?
        restrictions = {enumeration: []}
        ns.each do |c|
          if c.name == 'enumeration'
            restrictions[c.name.to_sym] << c['value']
          else
            restrictions[c.name.to_sym] = c['value']
          end
        end
        if restrictions[:enumeration].none?
          restrictions.delete(:enumeration)
        end
        set_last(n, restrictions.merge(base: base))
      end

    when 'attribute'
      enter(n, depth, opts.merge(key_for_depth(depth) => '+'))

      allowed_attributes(n, required: ['name'], optional: %w(type use fixed))
      ns = node_set(n.element_children, size: 0..1, names: ['simpleType'], children: true)
      if ns.any?
        elements(ns[0], depth, opts)
      end

      follow(n, depth, opts.merge(reference: n['type']), true)

    when 'simpleContent'
      allowed_attributes(n)
      ns = node_set(n.element_children, size: 1, names: ['extension'], attributes: ['base'], children: true)

      base = ns[0]['base']
      # TODO follow/set `base` reference

      ns = node_set(ns[0].element_children, size: 1, names: ['attribute'], name_only: true)
      elements(ns[0], depth, opts)

    when 'complexContent'
      allowed_attributes(n)
      ns = node_set(n.element_children, size: 1, names: %w(extension restriction), name_only: true)

      base = ns[0]['base']
      # TODO follow/set `base` reference

      case ns[0].name
      when 'extension'
        names = %w(attribute choice group sequence)
      when 'restriction'
        names = ['sequence']
      else
        assert false, "unexpected #{n.name}", n
      end

      allowed_attributes(ns[0], required: ['base'])
      ns = node_set(ns[0].element_children, size: 0..1, names: names, name_only: true)
      ns.each do |c|
        elements(c, depth, opts)
      end

    else
      assert false, "unexpected #{n.name}", n
    end
  end
end