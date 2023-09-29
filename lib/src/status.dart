enum FusionStatus {
  setup("setup"),
  waiting("waiting"),
  connecting("connecting"),
  running("running"),
  complete("complete"),
  failed("failed"),
  exception("Exception");

  const FusionStatus(this.value);

  final String value;
}
