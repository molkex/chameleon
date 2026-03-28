import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";

const PERIODS = [
  { value: "7", label: "7д" },
  { value: "30", label: "30д" },
  { value: "90", label: "90д" },
  { value: "365", label: "1г" },
] as const;

export function PeriodSelector({
  value,
  onChange,
}: {
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <Tabs value={value} onValueChange={onChange}>
      <TabsList>
        {PERIODS.map((p) => (
          <TabsTrigger key={p.value} value={p.value}>
            {p.label}
          </TabsTrigger>
        ))}
      </TabsList>
    </Tabs>
  );
}
