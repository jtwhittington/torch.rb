require "yaml"
# use require_relative for
# rake generate:function (without bundle)
require_relative "function"

def generate_functions
  functions = load_functions
  functions = skip_functions(functions)
  functions = group_functions(functions)

  generate_files("torch", :define_singleton_method, functions[:torch])
  generate_files("tensor", :define_method, functions[:tensor])
  generate_files("nn", :define_singleton_method, functions[:nn])
  generate_files("linalg", :define_singleton_method, functions[:linalg])
end

def load_functions
  path = File.expand_path("native_functions.yaml", __dir__)
  YAML.load_file(path).map { |f| Function.new(f) }.sort_by(&:name)
end

def skip_functions(functions)
  functions.reject do |f|
    f.base_name.start_with?("_") ||
    f.base_name.include?("_backward") ||
    f.base_name.include?("_forward") ||
    f.base_name == "to" ||
    f.base_name == "record_stream" ||
    # in ext.cpp
    f.base_name == "index" ||
    f.base_name == "index_put_" ||
    # need to add to ext.cpp
    f.base_name == "index_put" ||
    # not supported yet
    f.func.include?("Dimname") ||
    f.func.include?("ConstQuantizerPtr")
  end
end

def group_functions(functions)
  nn_functions, other_functions = functions.partition { |f| f.python_module == "nn" }
  linalg_functions, other_functions = other_functions.partition { |f| f.python_module == "linalg" }
  unexpected_functions, other_functions = other_functions.partition { |f| f.python_module }
  torch_functions = other_functions.select { |f| f.variants.include?("function") }
  tensor_functions = other_functions.select { |f| f.variants.include?("method") }

  if unexpected_functions.any?
    unexpected_modules = unexpected_functions.map(&:python_module).uniq
    raise "Unexpected modules: #{unexpected_modules.join(", ")}" unless unexpected_modules.sort == ["fft", "special"]
  end

  {torch: torch_functions, tensor: tensor_functions, nn: nn_functions, linalg: linalg_functions}
end

def generate_files(type, def_method, functions)
  method_defs = []
  attach_defs = []
  functions.group_by(&:base_name).each do |name, grouped_functions|
    method_defs << generate_method_def(name, grouped_functions, type, def_method)
    attach_defs << generate_attach_def(name, type, def_method)
  end
  write_header(type)
  write_body(type, method_defs, attach_defs)
end

def write_header(type)
  template = <<~EOS
    // generated by rake generate:functions
    // do not edit by hand

    #pragma once

    void add_%{type}_functions(Rice::Module& m);
  EOS

  contents = template % {type: type}
  write_file("#{type}_functions.h", contents)
end

def write_body(type, method_defs, attach_defs)
  template = <<~EOS
    // generated by rake generate:functions
    // do not edit by hand

    #include <torch/torch.h>
    #include <rice/rice.hpp>

    #include "ruby_arg_parser.h"
    #include "templates.h"
    #include "wrap_outputs.h"

    %{method_defs}
    void add_%{type}_functions(Rice::Module& m) {
      %{attach_defs}
    }
  EOS

  contents = template % {
    type: type,
    method_defs: method_defs.join("\n"),
    attach_defs: attach_defs.join("\n  ")
  }
  write_file("#{type}_functions.cpp", contents)
end

def write_file(name, contents)
  path = File.expand_path("../ext/torch", __dir__)
  File.write(File.join(path, name), contents)
end

def generate_attach_def(name, type, def_method)
  ruby_name =
    if name.end_with?("_")
      "#{name[0..-2]}!"
    elsif name.start_with?("is_")
      "#{name[3..-1]}?"
    else
      name
    end

  ruby_name = "_#{ruby_name}" if ["size", "stride", "random!", "stft"].include?(ruby_name)
  ruby_name = ruby_name.sub(/\Alinalg_/, "") if type == "linalg"

  # cast for Ruby < 2.7 https://github.com/thisMagpie/fftw/issues/22#issuecomment-49508900
  cast = RUBY_VERSION.to_f > 2.7 ? "" : "(VALUE (*)(...)) "

  full_name = type == "linalg" && name.start_with?("linalg_") ? name : "#{type}_#{name}"

  "rb_#{def_method}(m, \"#{ruby_name}\", #{cast}#{full_name}, -1);"
end

def generate_method_def(name, functions, type, def_method)
  assign_self = type == "tensor" ? "\n  Tensor& self = Rice::detail::From_Ruby<Tensor&>().convert(self_);" : ""

  functions = group_overloads(functions, type)
  signatures = functions.map { |f| f["signature"] }
  max_args = signatures.map { |s| s.count(",") - s.count("*") }.max + 1
  dispatches = add_dispatches(functions, def_method)

  full_name = type == "linalg" && name.start_with?("linalg_") ? name : "#{type}_#{name}"

  template = <<~EOS
    // #{name}
    static VALUE #{full_name}(int argc, VALUE* argv, VALUE self_)
    {
      HANDLE_TH_ERRORS#{assign_self}
      static RubyArgParser parser({
        #{signatures.map(&:inspect).join(",\n    ")}
      });
      ParsedArgs<#{max_args}> parsed_args;
      #{dispatches.include?("_r.") ? "auto _r = " : ""}parser.parse(self_, argc, argv, parsed_args);
      #{dispatches}
      END_HANDLE_TH_ERRORS
    }
  EOS
end

def indent(code)
  code.split("\n").join("\n  ")
end

def add_dispatches(functions, def_method)
  if functions.size == 1
    add_dispatch(functions.first, def_method)
  else
    body = []
    functions.each_with_index do |f, i|
      body << "case #{i}: {
      #{add_dispatch(f, def_method).split("\n").join("\n    ")}
    }"
    end

    "switch (_r.idx) {
    #{body.join("\n    ")}
  }
  RETURN_NIL"
  end
end

def add_dispatch(function, def_method)
  if function["out"] && function["out"] != function["base"]
    base_code = generate_dispatch(function["base"], def_method)
    out_code = generate_dispatch(function["out"], def_method)
    out_index = function["out"].out_index

    return "if (_r.isNone(#{out_index})) {
    #{indent(base_code)}
  } else {
    #{indent(out_code)}
  }"
  else
    generate_dispatch(function["base"], def_method)
  end
end

def group_overloads(functions, type)
  grouped = Hash.new { |hash, key| hash[key] = {} }

  functions.each do |function|
    signature = generate_signature(function, type, skip_out: true)
    v = grouped[signature]
    if function.out?
      v["out"] = function
      v["signature"] = generate_signature(function, type)

      # for now
      v["base"] ||= function
    else
      v["base"] = function
      v["signature"] ||= signature
    end
  end

  puts "Missing base: #{functions.first.name}" if grouped.any? { |_, v| !v["base"] }
  sort_functions(grouped.values)
end

def sort_functions(functions)
  # TODO
  functions.sort_by { |f| f["out"] ? 1 : 0 }
end

def generate_dispatch(function, def_method)
  cpp_name = function.base_name
  cpp_name += "_out" if function.out?

  remove_self = def_method == :define_method

  params = function.params.map(&:dup)
  set_param_position(params, remove_self)
  params, opt_params = split_opt_params(params)
  opt_index = opt_params.map { |v| v[:position] }.min if opt_params.any?

  cpp_params = generate_dispatch_params(function, params)
  if opt_index
    cpp_params.insert(remove_self ? opt_index + 1 : opt_index, "const TensorOptions & options")
  end

  retval = generate_dispatch_retval(function)
  dispatch_code = generate_dispatch_code(function, def_method, params, opt_index, remove_self)
  function_code = generate_function_code(function, cpp_name, params, opt_index, remove_self)

  out_var = generate_out_var(function.out_index, function.retvals.size) if function.out? && function.retvals.size > 1 && function.retvals.all? { |v| v[:type] == "Tensor" }
  tensor_options = generate_tensor_options(function, opt_params) if opt_params.any?

  "// #{function.func}#{tensor_options}#{out_var}
  auto dispatch_#{cpp_name} = [](#{cpp_params.join(", ")}) -> #{retval} {
    // in future, release GVL
    #{dispatch_code}
  };
  #{function_code}"
end

def generate_out_var(out_index, size)
  "\n  auto out = _r.tensorlist_n<#{size}>(#{out_index});"
end

def set_param_position(params, remove_self)
  i = 0
  params.each do |v|
    next if remove_self && v[:name] == "self"
    v[:position] = i
    i += 1
  end
end

def split_opt_params(params)
  option_names = ["dtype", "device", "layout", "requires_grad", "pin_memory"]

  opt_params, other_params = params.partition { |v, i| option_names.include?(v[:name]) }
  if opt_params.size >= 4
    [other_params, opt_params]
  else
    [params, []]
  end
end

def generate_tensor_options(function, opt_params)
  code = "\n  const auto options = TensorOptions()"
  order = ["dtype", "device", "layout", "requires_grad", "pin_memory"]
  opt_params.sort_by { |v| order.index(v[:name]) }.each do |opt|
    i = opt[:position]

    c =
      case opt[:name]
      when "dtype"
        if function.base_name == "arange"
          "dtype(_r.scalartypeOptional(#{i}))"
        else
          "dtype(_r.scalartype(#{i}))"
        end
      when "device"
        "device(_r.device(#{i}))"
      when "layout"
        "layout(_r.layoutOptional(#{i}))"
      when "requires_grad"
        "requires_grad(_r.toBool(#{i}))"
      when "pin_memory"
        "pinned_memory(_r.toBool(#{i}))"
      end

    code += "\n      .#{c}"
  end

  "#{code};"
end

def generate_function_code(function, cpp_name, params, opt_index, remove_self)
  params = generate_function_params(function, params, remove_self)
  if opt_index
    opt_index += 1 if remove_self
    params.insert(opt_index, "options")
  end

  code = "dispatch_#{cpp_name}(#{params.join(", ")})"
  if function.retvals.empty?
    "#{code};\nRETURN_NIL"
  else
    "return wrap(#{code});"
  end
end

def generate_function_params(function, params, remove_self)
  out_var = function.out? && function.retvals.size > 1 && function.retvals.all? { |v| v[:type] == "Tensor" }

  i = 0
  params.map do |param|
    i += 1

    next "self" if remove_self && param[:name] == "self"
    if out_var && i > function.out_index
      next "out[#{i - function.out_index - 1}]"
    end

    func =
      case param[:type]
      when "Tensor"
        "tensor"
      when "Tensor[]"
        "tensorlist"
      when "Scalar[]"
        "scalarlist"
      when /\Aint\[/
        "intlist"
      when "float[]"
        "doublelist"
      when "Scalar"
        "scalar"
      when "bool"
        "toBool"
      when "int"
        "toInt64"
      when "float"
        "toDouble"
      when "ScalarType"
        "scalartype"
      when "str"
        "string"
      when "Generator"
        "generator"
      when "MemoryFormat"
        "memoryformat"
      when "Storage"
        "storage"
      else
        raise "Unknown type: #{param[:type]} (#{function.name})"
      end

    if param[:optional]
      func =
        case func
        when "tensor"
          if function.out?
            "tensor"
          else
            "optionalTensor"
          end
        when "generator", "tensorlist", "intlist"
          func
        else
          "#{func}Optional"
        end
      end

    "_r.#{func}(#{param[:position]})"
  end
end

def generate_dispatch_code(function, def_method, params, opt_index, remove_self)
  # torch::empty sets requires_grad by at::empty doesn't
  # https://github.com/pytorch/pytorch/issues/36455
  prefix = remove_self ? "self." : (opt_index ? "torch::" : "at::")
  dispatch = function.out? ? "#{function.base_name}_out" : function.base_name

  params = params.map { |v| v[:name] }
  params.reject! { |v| v == "self" } if remove_self
  params.insert(opt_index, "options") if opt_index

  if function.out_index
    params.unshift(params.slice!(function.out_index, function.retvals.size))
  end

  code = "#{prefix}#{dispatch}(#{params.join(", ")});"
  code = "return #{code}" unless function.retvals.empty?
  code
end

def generate_dispatch_params(function, params)
  params.map do |param|
    type =
      case param[:type]
      when "Tensor"
        if param[:optional]
          if function.out?
            "const Tensor &"
          else
            # TODO
            # "const c10::optional<at::Tensor> &"
            "const OptionalTensor &"
          end
        elsif param[:modifier]
          if param[:modifier].include?("!") && function.retvals.size > 1
            "Tensor &"
          else
            "Tensor"
          end
        else
          "const Tensor &"
        end
      when "Tensor[]"
        "TensorList"
      when "Scalar[]"
        "ScalarList"
      when "int"
        "int64_t"
      when "float"
        "double"
      when /\Aint\[/
        "IntArrayRef"
      when "float[]"
        "ArrayRef<double>"
      when "str"
        "std::string"
      when "Scalar", "bool", "ScalarType", "Layout", "Device", "Storage", "Generator", "MemoryFormat", "Storage"
        param[:type]
      else
        raise "Unknown type: #{param[:type]} (#{function.name})"
      end

    if param[:optional] && param[:type] != "Tensor"
      type = "c10::optional<#{type}>"
    end

    "#{type} #{param[:name]}"
  end
end

def generate_dispatch_retval(function)
  types = function.retvals.map { |r| r[:type] }

  case types
  when []
    "void"
  when ["bool"]
    "bool"
  when ["int"]
    "int64_t"
  when ["float"]
    "double"
  when ["Scalar"]
    "Scalar"
  when ["ScalarType"]
    "ScalarType"
  when ["QScheme"]
    "QScheme"
  when ["Tensor"]
    "Tensor"
  when ["Tensor[]"]
    "std::vector<Tensor>"
  when ["Tensor", "Tensor"]
    "std::tuple<Tensor,Tensor>"
  when ["Tensor", "Tensor", "Tensor"]
    "std::tuple<Tensor,Tensor,Tensor>"
  when ["Tensor", "Tensor", "Tensor", "Tensor"]
    "std::tuple<Tensor,Tensor,Tensor,Tensor>"
  when ["Tensor", "Tensor", "Tensor", "Tensor", "Tensor"]
    "std::tuple<Tensor,Tensor,Tensor,Tensor,Tensor>"
  when ["Tensor", "Tensor", "float", "int"]
    "std::tuple<Tensor,Tensor,double,int>"
  when ["float", "float"]
    "std::tuple<double,double>"
  else
    raise "Unknown retvals: #{types}"
  end
end

def generate_signature(function, type, skip_out: false)
  params = function.params.dup
  if function.out?
    if skip_out
      # remove out
      params.slice!(function.out_index, function.retvals.size)
    elsif function.retvals.size > 1 && params[function.out_index, function.retvals.size].all? { |r| r[:type] == "Tensor" }
      # combine tensor into tensorlist
      list_size = function.retvals.size
      params.slice!(function.out_index, list_size)
      params.insert(function.out_index, {name: "out", type: "Tensor[#{list_size}]", list_size: list_size, keyword_only: true})
    end
  end

  parts = params.select { |v| !v[:keyword_only] && !(type == "tensor" && v[:name] == "self") }
  keyword_only_parts = params.select { |v| v[:keyword_only] }
  if keyword_only_parts.any?
    parts << "*"
    parts.concat(keyword_only_parts)
  end

  "#{function.base_name}(#{parts.map { |v| signature_param(v) }.join(", ")})"
end

def signature_param(param)
  return "*" if param == "*"

  name = param[:name]
  name = "input" if name == "self"

  sig = "#{signature_type(param)} #{name}"
  case param[:default]
  when nil
    # do nothing
  when "[]"
    sig += "=None"
  when "Mean"
    sig += "=at::Reduction::Mean"
  else
    sig += "=#{param[:default]}"
  end

  # hack
  sig += "=None" if param[:name] == "out"

  sig
end

def signature_type(param)
  type =
    case param[:type]
    when "Tensor", /\ATensor\([a-z]!?\)\z/
      "Tensor"
    when /\Tensor\[\d*\]\z/
      "TensorList"
    when "Scalar[]"
      "ScalarList"
    when /\ADimname\[\d*\]\z/
      "DirnameList"
    when /\Aint\[\d*\]\z/
      "IntArrayRef"
    when "int"
      "int64_t"
    when "float"
      "double"
    when "str"
      "std::string"
    when "Scalar", "Dimname", "bool", "ScalarType", "Layout", "Device", "Generator", "MemoryFormat", "Storage"
      param[:type]
    when "float[]"
      "ArrayRef<double>"
    else
      raise "Unknown type: #{param[:type]}"
    end

  type += "[#{param[:list_size]}]" if param[:list_size]
  type += "?" if param[:optional]
  type
end
