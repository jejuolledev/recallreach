/// RecallReach interoperability production.
///   RecallFeed (custom inbound adapter) -> RecallTriage (BPL)
///       -> RecallReaderAgent (IRIS AI Hub agent: reads + decides)
///       -> PatientMatcher (SQL + Vector Search + Embedded Python)
///   ApprovalIntake -> ApprovalFlow (BPL) -> Pharmacist (Workflow Engine, 10 min) -> ActionExecutor
Class RecallReach.Production Extends Ens.Production
{

XData ProductionDefinition
{
<Production Name="RecallReach.Production" TestingEnabled="false" LogGeneralTraceEvents="false">
  <Description>FDA recall -> AI Hub agent -> ranked patients -> pharmacist approval (Workflow) -> holds and calls</Description>
  <ActorPoolSize>2</ActorPoolSize>
  <Item Name="RecallFeed" Category="RecallReach" ClassName="RecallReach.Service.RecallFeed" PoolSize="1" Enabled="true" Foreground="false" LogTraceEvents="false">
    <Setting Target="Adapter" Name="CallInterval">1</Setting>
    <Setting Target="Adapter" Name="Source">queue</Setting>
  </Item>
  <Item Name="ApprovalIntake" Category="RecallReach" ClassName="RecallReach.Service.ApprovalIntake" PoolSize="0" Enabled="true" />
  <Item Name="BenchmarkRunner" Category="RecallReach" ClassName="RecallReach.Service.BenchmarkRunner" PoolSize="0" Enabled="true" />
  <Item Name="RecallTriage" Category="RecallReach" ClassName="RecallReach.Process.RecallTriage" PoolSize="1" Enabled="true" />
  <Item Name="ApprovalFlow" Category="RecallReach" ClassName="RecallReach.Process.ApprovalFlow" PoolSize="1" Enabled="true" />
  <Item Name="RecallReaderAgent" Category="RecallReach" ClassName="RecallReach.Operation.RecallReaderAgent" PoolSize="1" Enabled="true">
    <Setting Target="Adapter" Name="AgentClass">RecallReach.AI.RecallReaderAgent</Setting>
  </Item>
  <Item Name="PatientMatcher" Category="RecallReach" ClassName="RecallReach.Operation.PatientMatcher" PoolSize="1" Enabled="true" />
  <Item Name="ActionExecutor" Category="RecallReach" ClassName="RecallReach.Operation.ActionExecutor" PoolSize="1" Enabled="true" />
  <Item Name="Pharmacist" Category="RecallReach" ClassName="EnsLib.Workflow.Operation" PoolSize="1" Enabled="true">
    <Setting Target="Host" Name="AutoCreateRole">1</Setting>
  </Item>
</Production>
}

}
