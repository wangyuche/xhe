#!/usr/bin/ruby
# YAML stream -> JSON(安全:只從節點樹建構純量 / map / 陣列,不實例化任何物件,不展開 tag)。
# 用法:ruby yaml2json.rb <檔案>...   (檔名 "-" 讀 stdin)
# 輸出:[{"file":…, "doc":序號, "line":起始行, "obj":…, "lines":{"/spec/x":行,…}}, …]
# 行號從 1 起算。別名(*ref)一律拒絕(結束碼 1),避免 billion-laughs。
require 'psych'
require 'json'

def scalar_value(node)
  return node.value if node.quoted || node.style == Psych::Nodes::Scalar::LITERAL || node.style == Psych::Nodes::Scalar::FOLDED
  return node.value if node.tag && node.tag != 'tag:yaml.org,2002:int' && node.tag != 'tag:yaml.org,2002:bool'
  v = node.value
  case v
  when '', '~', 'null', 'Null', 'NULL' then nil
  # Kubernetes 用的 YAML 1.1 布林(sigs.k8s.io/yaml → go-yaml v2)
  when 'true', 'True', 'TRUE', 'yes', 'Yes', 'YES', 'on', 'On', 'ON', 'y', 'Y' then true
  when 'false', 'False', 'FALSE', 'no', 'No', 'NO', 'off', 'Off', 'OFF', 'n', 'N' then false
  when /\A[-+]?(0|[1-9][0-9]*)\z/ then v.to_i
  when /\A[-+]?([0-9]+\.[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?\z/ then v.to_f
  else v
  end
end

def esc(k)
  k.to_s.gsub('~', '~0').gsub('/', '~1')
end

def build(node, path, lines)
  lines[path.empty? ? '/' : path] = node.start_line + 1
  case node
  when Psych::Nodes::Scalar
    scalar_value(node)
  when Psych::Nodes::Sequence
    node.children.each_with_index.map { |c, i| build(c, "#{path}/#{i}", lines) }
  when Psych::Nodes::Mapping
    h = {}
    node.children.each_slice(2) do |k, v|
      raise 'alias not allowed' if k.is_a?(Psych::Nodes::Alias)
      key = k.is_a?(Psych::Nodes::Scalar) ? k.value : build(k, path, {}).to_s
      next if key == '<<'
      h[key] = build(v, "#{path}/#{esc(key)}", lines)
    end
    h
  when Psych::Nodes::Alias
    raise 'alias not allowed'
  else
    nil
  end
end

out = []
ARGV.each do |f|
  src = f == '-' ? STDIN.read : File.read(f)
  begin
    stream = Psych.parse_stream(src, filename: f)
  rescue Psych::SyntaxError => e
    STDERR.puts "yaml2json: #{f}: #{e.message}"
    exit 1
  end
  stream.children.each_with_index do |doc, i|
    next if doc.root.nil?
    lines = {}
    begin
      obj = build(doc.root, '', lines)
    rescue RuntimeError => e
      STDERR.puts "yaml2json: #{f} doc #{i}: #{e.message}"
      exit 1
    end
    next if obj.nil?
    out << { 'file' => f, 'doc' => i, 'line' => doc.root.start_line + 1, 'obj' => obj, 'lines' => lines }
  end
end
puts JSON.generate(out)
