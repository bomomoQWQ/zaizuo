// AOT 工具链诊断探针，不含业务状态或秘密，不进入发布包。
void main(List<String> args) {
  print('zaizuo-aot-probe:${args.isEmpty ? "ok" : args.first}');
}
