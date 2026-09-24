(() => {
  // This runs in the already loaded page. It deliberately uses the public DOM
  // and ECharts instances exposed by the page; it does not issue API requests
  // or read a canvas screenshot.
  const warnings = [];
  const finite = (value) => typeof value === "number" && Number.isFinite(value);
  const text = (value) => {
    if (value === undefined || value === null) return "";
    if (typeof value === "string" || typeof value === "number") return String(value);
    if (Array.isArray(value)) return value.map(text).filter(Boolean).join(" ");
    if (typeof value === "object") {
      return text(value.text || value.name || value.value || value.title);
    }
    return "";
  };
  const lower = (value) => text(value).toLowerCase();
  const optionArray = (value) => Array.isArray(value) ? value : (value ? [value] : []);

  const parseNumber = (value) => {
    if (finite(value)) return value;
    if (typeof value !== "string") return null;
    const trimmed = value.trim().replace(/,/g, "");
    const match = trimmed.match(/^(-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?)(?:\s*(k|khz|hz))?$/i);
    if (!match) return null;
    let number = Number(match[1]);
    if (!Number.isFinite(number)) return null;
    if (match[2] && match[2].toLowerCase().startsWith("k")) number *= 1000;
    return number;
  };

  const axisUnitMultiplier = (axis) => {
    const axisText = lower(axis && (axis.name || axis.nameText || axis.axisLabel));
    if (axisText.includes("khz") || axisText.includes("千赫")) return 1000;
    return 1;
  };

  const parseFrequency = (value, axis) => {
    const parsed = parseNumber(value);
    if (parsed === null) return null;
    // A numeric value with a kHz axis is usually expressed in kHz. Explicit
    // textual units have already been converted by parseNumber.
    if (typeof value === "number") return parsed * axisUnitMultiplier(axis);
    const valueText = lower(value);
    if (!valueText.includes("hz") && !valueText.includes("k")) {
      return parsed * axisUnitMultiplier(axis);
    }
    return parsed;
  };

  const titleText = (option) => optionArray(option && option.title)
    .map((item) => text(item && (item.text || item.subtext || item.name)))
    .filter(Boolean)
    .join(" ");

  const classify = (value) => {
    const normalized = lower(value);
    if (normalized.includes("thd") || normalized.includes("谐波") || normalized.includes("失真") || normalized.includes("distortion") || /h[234].*%/.test(normalized)) {
      return "harmonicDistortion";
    }
    if (normalized.includes("phase") || normalized.includes("相位")) return "phase";
    if (normalized.includes("impedance") || normalized.includes("阻抗")) return "impedance";
    if (normalized.includes("deviation") || normalized.includes("动态线性") || normalized.includes("线性偏离")) {
      return "dynamicDeviation";
    }
    if (normalized.includes("频响") || normalized.includes("frequency response") || normalized.includes("frequency")) {
      return "frequencyResponse";
    }
    return "unknown";
  };

  const inferChannel = (value) => {
    const normalized = lower(value);
    if (normalized.includes("left") || normalized.includes("左") || normalized === "l") return "left";
    if (normalized.includes("right") || normalized.includes("右") || normalized === "r") return "right";
    if (normalized.includes("平均") || normalized.includes("average") || normalized.includes("mean")) return "average";
    return null;
  };

  const inferRole = (value) => {
    const normalized = lower(value);
    if (normalized.includes("参考") || normalized.includes("target") || normalized.includes("reference")) {
      return "reference";
    }
    if (normalized.includes("对比") || normalized.includes("compare") || normalized.includes("相似")) {
      return "comparison";
    }
    return "unknown";
  };

  const getChartForElement = (element) => {
    try {
      if (window.echarts && typeof window.echarts.getInstanceByDom === "function") {
        return window.echarts.getInstanceByDom(element) || null;
      }
    } catch (_) {}
    return null;
  };

  const chartRoots = () => {
    const roots = [];
    const seen = new Set();
    const add = (element) => {
      if (!element || seen.has(element)) return;
      const chart = getChartForElement(element);
      if (!chart) return;
      seen.add(element);
      roots.push({ element, chart });
    };

    document.querySelectorAll("[_echarts_instance_], .echarts, [class*='echarts'], canvas").forEach((element) => {
      add(element);
      // ECharts renders into a canvas inside the chart root. Walking a few
      // parents still stays within the normal page DOM and avoids OCR/image
      // extraction when the root itself is not marked with a class.
      let parent = element.parentElement;
      for (let depth = 0; parent && depth < 4; depth += 1, parent = parent.parentElement) add(parent);
    });
    return roots;
  };

  // The public page currently renders its chart through a React wrapper. The
  // page chunk passes the following shape to that wrapper:
  //   { datas: [{ name, dataSet, defaultShow }], project: { rule: ... } }
  // and the wrapper creates an ECharts `option` with `xAxis` and `series`.
  // Umi/webpack does not necessarily publish `window.echarts`, so inspect only
  // the already mounted React props/fibers as a fallback. This reads values
  // already present in the page; it does not fetch or reconstruct a private
  // endpoint response.
  const reactChartOptions = () => {
    const options = [];
    const seenOptions = new Set();
    const seenProps = new Set();
    const visited = new Set();
    const add = (option, project, path, element) => {
      if (!option || !Array.isArray(option.series) || seenOptions.has(option)) return;
      if (!option.xAxis && !option.yAxis) return;
      seenOptions.add(option);
      options.push({ option, project, path, element });
    };
    const inspectProps = (props, path, element, depth = 0) => {
      if (!props || typeof props !== "object") return;
      if (depth > 24 || seenProps.has(props)) return;
      seenProps.add(props);
      if (Array.isArray(props)) {
        props.slice(0, 200).forEach((child, index) => {
          if (child && typeof child === "object") inspectProps(child, `${path}[${index}]`, element, depth + 1);
        });
        return;
      }
      if (props.option && typeof props.option === "object") {
        add(props.option, props.project || null, `${path}.option`, element);
      }
      // React props can be wrapped in memo/forwardRef objects. Only traverse
      // the known props containers, not arbitrary application state.
      ["children", "props", "memoizedProps", "pendingProps"].forEach((key) => {
        const child = props[key];
        if (child && typeof child === "object" && child !== props) {
          inspectProps(child, `${path}.${key}`, element, depth + 1);
        }
      });
    };
    const walkFiber = (fiber, path, depth, element) => {
      if (!fiber || depth > 24 || visited.has(fiber)) return;
      visited.add(fiber);
      inspectProps(fiber.memoizedProps, `${path}.memoizedProps`, element);
      inspectProps(fiber.pendingProps, `${path}.pendingProps`, element);
      walkFiber(fiber.child, `${path}.child`, depth + 1, element);
      walkFiber(fiber.sibling, `${path}.sibling`, depth, element);
    };

    const elements = Array.from(document.querySelectorAll("*"));
    elements.slice(0, 8000).forEach((element) => {
      Object.keys(element).forEach((key) => {
        if (key.indexOf("__reactProps$") === 0) {
          inspectProps(element[key], key, element);
        } else if (key.indexOf("__reactFiber$") === 0) {
          walkFiber(element[key], key, 0, element);
        }
      });
    });
    return options;
  };

  const toPairs = (series, xAxis) => {
    const data = Array.isArray(series && series.data) ? series.data : [];
    const categoryValues = xAxis && Array.isArray(xAxis.data) ? xAxis.data : [];
    const pairs = [];
    data.forEach((item, index) => {
      let xValue = null;
      let yValue = null;
      if (Array.isArray(item)) {
        if (item.length >= 2) {
          xValue = item[0];
          yValue = item[1];
        }
      } else if (item && typeof item === "object") {
        const value = item.value;
        if (Array.isArray(value) && value.length >= 2) {
          xValue = value[0];
          yValue = value[1];
        } else {
          yValue = value;
          xValue = categoryValues[index];
        }
      } else {
        yValue = item;
        xValue = categoryValues[index];
      }
      const frequencyHz = parseFrequency(xValue, xAxis);
      const decibels = parseNumber(yValue);
      if (frequencyHz === null || decibels === null || !finite(frequencyHz) || !finite(decibels)) return;
      if (frequencyHz <= 0 || frequencyHz > 200000) return;
      pairs.push({ frequencyHz, decibels });
    });
    return pairs;
  };

  const looksLikeFrequencyCurve = (pairs, xAxis, series, option) => {
    if (pairs.length < 2) return false;
    const axisName = lower(xAxis && xAxis.name);
    const labels = lower(`${titleText(option)} ${text(series && series.name)} ${axisName}`);
    const explicitFrequency = labels.includes("频响") || labels.includes("frequency") || labels.includes("hz") || labels.includes("频率");
    let increasing = 0;
    for (let index = 1; index < pairs.length; index += 1) {
      if (pairs[index].frequencyHz >= pairs[index - 1].frequencyHz) increasing += 1;
    }
    const monotonic = increasing >= Math.max(1, Math.floor((pairs.length - 1) * 0.8));
    return explicitFrequency || monotonic;
  };

  const extract = [];
  const extractOption = (option, element, chartIndex, extractionSource, evidencePath, project) => {
    if (!option) return;
    const xAxes = optionArray(option && option.xAxis);
    const yAxes = optionArray(option && option.yAxis);
    const chartTitle = titleText(option) || text(project && (project.name || project.title));
    const chartKind = classify(`${chartTitle} ${text(xAxes[0] && xAxes[0].name)} ${text(yAxes[0] && yAxes[0].name)}`);
    const seriesList = optionArray(option && option.series);
    seriesList.forEach((series, seriesIndex) => {
      const xAxisIndex = Number.isInteger(series && series.xAxisIndex) ? series.xAxisIndex : 0;
      const xAxis = xAxes[xAxisIndex] || xAxes[0] || {};
      const pairs = toPairs(series, xAxis);
      if (!looksLikeFrequencyCurve(pairs, xAxis, series, option)) return;
      const seriesName = text(series && (series.name || series.id)) || `series-${seriesIndex + 1}`;
      const labels = `${chartTitle} ${seriesName} ${text(xAxis.name)} ${text(yAxes[0] && yAxes[0].name)}`;
      const kind = classify(labels) === "unknown" ? chartKind : classify(labels);
      extract.push({
        id: `${extractionSource}:${chartIndex}:${seriesIndex}`,
        chartTitle,
        seriesName,
        curveKind: kind,
        channel: inferChannel(seriesName),
        role: inferRole(`${chartTitle} ${seriesName}`),
        points: pairs,
        pointCount: pairs.length,
        sourceElementId: element && element.id ? element.id : null,
        xAxisName: text(xAxis.name),
        yAxisName: text(yAxes[0] && yAxes[0].name),
        hasLogarithmicXAxis: String(xAxis.type || "").toLowerCase() === "log",
        extractionSource,
        evidencePath: evidencePath || null,
        // Only an explicitly classified frequency-response series is safe to
        // import automatically. Unknown/THD/phase series remain visible for
        // human inspection but require an explicit type decision upstream.
        selectable: pairs.length >= 2 && kind === "frequencyResponse"
      });
    });
  };

  const roots = chartRoots();
  roots.forEach(({ element, chart }, chartIndex) => {
    let option;
    try {
      option = chart.getOption();
    } catch (_) {
      warnings.push(`无法读取第 ${chartIndex + 1} 个公开 ECharts 实例`);
      return;
    }
    extractOption(option, element, chartIndex, "echartsInstance", "echarts.getInstanceByDom().getOption()", null);
  });

  if (roots.length === 0) {
    const reactOptions = reactChartOptions();
    reactOptions.forEach((item, index) => {
      extractOption(item.option, item.element, index, "reactProps", item.path, item.project);
    });
    if (reactOptions.length > 0) warnings.push("未发现 window.echarts；已读取页面已挂载 React 图表 props 中的公开 option");
  }

  // Some ECharts wrappers expose the same option through both a canvas root
  // and a nested chart element. Keep the first exact numeric copy so the UI
  // presents one selectable candidate per actual series.
  const uniqueExtract = [];
  const signatures = new Set();
  extract.forEach((candidate) => {
    const first = candidate.points[0] || {};
    const last = candidate.points[candidate.points.length - 1] || {};
    const signature = [
      candidate.curveKind,
      candidate.chartTitle || "",
      candidate.seriesName,
      candidate.channel || "",
      candidate.points.length,
      first.frequencyHz,
      first.decibels,
      last.frequencyHz,
      last.decibels
    ].join("|");
    if (signatures.has(signature)) return;
    signatures.add(signature);
    candidate.id = `${candidate.extractionSource}:${uniqueExtract.length}`;
    uniqueExtract.push(candidate);
  });

  if (!window.echarts && roots.length === 0 && uniqueExtract.length === 0) warnings.push("当前页面未公开暴露 ECharts 实例或 React 图表 option，未读取图片或截图数据");
  if (uniqueExtract.length === 0) warnings.push("当前页面没有可从公开 ECharts 实例读取的数值曲线");
  return {
    pageURL: location.href,
    pageTitle: document.title || null,
    extractedAt: new Date().toISOString(),
    curves: uniqueExtract,
    warnings
  };
})()
