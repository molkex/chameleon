import { AlertCircle, RefreshCw } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";

export function ErrorCard({ error, retry }: { error: Error; retry?: () => void }) {
  return (
    <Card className="border-destructive">
      <CardContent className="flex items-center gap-4 pt-6">
        <AlertCircle className="size-8 text-destructive shrink-0" />
        <div className="flex-1">
          <p className="font-medium">Ошибка загрузки</p>
          <p className="text-sm text-muted-foreground">{error.message}</p>
        </div>
        {retry && (
          <Button variant="outline" size="sm" onClick={retry}>
            <RefreshCw className="size-4 mr-1" /> Повторить
          </Button>
        )}
      </CardContent>
    </Card>
  );
}
