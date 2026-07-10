import { Badge } from '../../ui/components/Badge';
import { Panel } from './components/Panel';

export function SampleScreen() {
  return (
    <Panel padded>
      <Badge label="one" tone="info" />
      <Badge label="two" tone="warn" />
    </Panel>
  );
}
